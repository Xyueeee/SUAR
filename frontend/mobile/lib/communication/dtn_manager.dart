import 'dart:async';
import 'dart:convert';

import '../constants.dart';
import '../models/distress_bundle_model.dart';
import 'wifi_direct_manager.dart';

/// Store-carry-forward relay between Helpers (CLAUDE.md Section 11, 1.x Step 4).
class DTNManager {
  DTNManager({required this.wifiDirectManager});

  final WiFiDirectManager wifiDirectManager;

  final List<DistressBundleModel> storedBundles = [];
  final Set<String> seenBundleIds = {};

  // seenBundleIds only ever grows (this is a dedupe set, not the relay
  // queue — entries can't be removed when a bundle is delivered/expired
  // without risking a relayed duplicate looping back). Capped so an
  // unusually long-running Helper session in a busy mesh doesn't grow this
  // without bound — Dart's Set literal is a LinkedHashSet, so `.first` is
  // the oldest insertion, evicted on overflow.
  static const int _maxSeenBundleIds = 2000;

  void _markSeen(String bundleId) {
    seenBundleIds.add(bundleId);
    _trimSeenBundleIds();
  }

  void _trimSeenBundleIds() {
    while (seenBundleIds.length > _maxSeenBundleIds) {
      seenBundleIds.remove(seenBundleIds.first);
    }
  }

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  // Relay attempts can still resolve after the owning screen disposes this
  // manager (same race every other manager guards against) — a bare add()
  // then throws "Bad state: Cannot add new events after calling close".
  void _emit(String line) {
    if (!_statusController.isClosed) _statusController.add(line);
  }

  void onBundleReceived(DistressBundleModel bundle) {
    if (seenBundleIds.contains(bundle.bundleId)) {
      // The same bundleId can legitimately arrive again carrying REFRESHED
      // triage — a victim updates score/tier/location under one id every few
      // seconds, and re-pulls exist precisely to fetch that (see
      // HelperController._pullCooldown). SQLite and the backend already take
      // the newer copy (timestamp upsert); the relay queue must too, or every
      // further hop keeps forwarding the first-seen snapshot forever.
      final idx = storedBundles.indexWhere(
        (b) => b.bundleId == bundle.bundleId,
      );
      if (idx >= 0 && bundle.updatedAt.isAfter(storedBundles[idx].updatedAt)) {
        storedBundles[idx] = bundle;
        _syncManifest();
        _emit('Bundle ${bundle.bundleId} refreshed with newer data for relay');
      } else {
        _emit('Bundle ${bundle.bundleId} already seen, skipping');
      }
      return;
    }
    if (bundle.hopCount >= dtnMaxHopCount) {
      _emit('TTL exceeded: ${bundle.bundleId}');
      return;
    }
    _markSeen(bundle.bundleId);
    storedBundles.add(bundle);
    _emit(
      'Bundle ${bundle.bundleId} stored for relay (hopCount=${bundle.hopCount})',
    );
    _syncManifest();
  }

  /// Keeps the native side's cached manifest AND full relay-bundle cache
  /// (answered to a peer's "manifest"/"sync" request, see
  /// WifiDirectHelper.handleRequest) in sync with what this device actually
  /// holds. Fire-and-forget — a beat out of date just means the next relay
  /// contact sends/returns one bundle that turns out to already be known
  /// (harmless, dedupe absorbs it), not a correctness problem worth
  /// blocking on.
  void _syncManifest() {
    unawaited(
      wifiDirectManager.setManifest(
        storedBundles.map((b) => b.bundleId).toList(),
      ),
    );
    unawaited(
      wifiDirectManager.setRelayBundles(
        jsonEncode(storedBundles.map((b) => b.toJson()).toList()),
      ),
    );
  }

  /// Call when another SUAR Helper is detected nearby, to opportunistically
  /// exchange whatever each side doesn't already have. Asks for the peer's
  /// manifest first (see WifiDirectManager.requestManifest) rather than
  /// blindly re-sending everything on every contact — the receiver's
  /// seenBundleIds dedupe made resending harmless, but still wasteful over
  /// a radio link that's already the most fragile/expensive part of this
  /// whole pipeline.
  ///
  /// Genuinely bidirectional in a single contact, not just epidemic
  /// "eventually" propagation: the push (what the peer is missing) and the
  /// pull (what THIS device is missing, identified from the same manifest
  /// response) both ride wifiDirectManager.sync()'s one round trip, which
  /// the Wi-Fi Direct *client* always opens. That matters because the
  /// group owner's own outbound socket has never reliably worked on test
  /// hardware (see WifiDirectHelper.connectClientSocket) — folding both
  /// directions into the client's connection means a relay completes on
  /// first contact regardless of which side ended up group owner, instead
  /// of waiting for a future contact where the roles happen to invert.
  ///
  /// Returns the bundles pulled from the peer (already saved into
  /// storedBundles here), for the caller to also persist to SQLite/notify
  /// listeners — empty if the peer had nothing this device was missing.
  Future<List<DistressBundleModel>> relayMissing(
    String groupOwnerAddress,
    String helperDeviceId,
  ) async {
    final peerHas = await wifiDirectManager.requestManifest(groupOwnerAddress);
    final toSend = <DistressBundleModel>[];
    for (final bundle in List<DistressBundleModel>.from(storedBundles)) {
      if (bundle.hopCount >= dtnMaxHopCount) {
        _emit('TTL exceeded: ${bundle.bundleId}');
        storedBundles.remove(bundle);
        continue;
      }
      if (peerHas.contains(bundle.bundleId)) continue;
      // Relay metadata belongs only to the outgoing copy. The carrier's
      // stored bundle keeps its original path depth and triage timestamp.
      toSend.add(
        DistressBundleModel.fromJson({
          ...bundle.toJson(),
          'hopCount': bundle.hopCount + 1,
        }),
      );
    }
    _syncManifest();

    final ownIds = storedBundles.map((b) => b.bundleId).toList();
    final pushJson = jsonEncode(toSend.map((b) => b.toJson()).toList());
    // requestManifest just above succeeded on this same connection/address,
    // so a sync() failure right after it is more likely a one-off radio
    // hiccup (confirmed on real hardware: a SocketTimeoutException
    // immediately following a fast, successful manifest round trip to the
    // same peer) than a genuinely dead link — worth one quick retry before
    // giving up and waiting for the next BLE-triggered contact cycle
    // (~15s later), instead of always eating that full wait on a transient
    // failure.
    var response = await wifiDirectManager.sync(
      groupOwnerAddress,
      ownIds,
      pushJson,
    );
    if (response == null) {
      await Future.delayed(const Duration(milliseconds: 500));
      response = await wifiDirectManager.sync(
        groupOwnerAddress,
        ownIds,
        pushJson,
      );
    }
    if (response == null) {
      _emit('Sync with $helperDeviceId failed');
      return const [];
    }
    if (toSend.isNotEmpty) {
      _emit(
        'Relayed ${toSend.length} bundle(s) to $helperDeviceId '
        '(${peerHas.length} already had)',
      );
    }

    List<DistressBundleModel> pulled;
    try {
      final decoded = jsonDecode(response) as List;
      final candidates = decoded
          .cast<Map<String, dynamic>>()
          .map(DistressBundleModel.fromJson)
          .toList();
      // A pull is a device-to-device transfer exactly like a push, but the
      // peer serves its cached copies as-is (the native cache can't bump) —
      // count the hop on the receiving side, or pulled copies travel free
      // against dtnMaxHopCount.
      pulled = [];
      for (final bundle in candidates) {
        if (!seenBundleIds.add(bundle.bundleId)) continue;
        bundle.hopCount += 1;
        if (bundle.hopCount >= dtnMaxHopCount) {
          _emit('TTL exceeded after pull: ${bundle.bundleId}');
          continue;
        }
        pulled.add(bundle);
      }
      _trimSeenBundleIds();
    } catch (e) {
      // A corrupt/truncated response shouldn't crash the relay attempt —
      // the push half above already succeeded; just treat the pull half as
      // "nothing came back" and let the next contact retry it.
      _emit(
        'Sync response from $helperDeviceId was malformed: $e',
      );
      return const [];
    }
    if (pulled.isEmpty) {
      if (toSend.isEmpty) {
        _emit(
          '$helperDeviceId and this device already have the same bundles',
        );
      }
      return const [];
    }
    for (final bundle in pulled) {
      storedBundles.add(bundle);
    }
    _syncManifest();
    _emit(
      'Pulled ${pulled.length} bundle(s) from $helperDeviceId',
    );
    return pulled;
  }

  void dispose() {
    _statusController.close();
  }
}
