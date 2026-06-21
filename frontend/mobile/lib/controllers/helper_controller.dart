import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../communication/ble_manager.dart';
import '../communication/dtn_manager.dart';
import '../communication/wifi_direct_manager.dart';
import '../constants.dart';
import '../models/distress_bundle_model.dart';
import '../storage/sqlite_repository.dart';

class HelperController {
  HelperController()
    : bleManager = BLEManager(),
      wifiDirectManager = WiFiDirectManager(),
      repository = SQLiteRepository() {
    dtnManager = DTNManager(wifiDirectManager: wifiDirectManager);
  }

  final BLEManager bleManager;
  final WiFiDirectManager wifiDirectManager;
  final SQLiteRepository repository;
  late final DTNManager dtnManager;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _bundleController =
      StreamController<List<DistressBundleModel>>.broadcast();
  Stream<List<DistressBundleModel>> get bundleStream =>
      _bundleController.stream;

  static const int _maxAckAttempts = 4;
  static const Duration _ackRetryDelay = Duration(seconds: 2);
  // Once a victim is successfully ack'd, ignore re-detections of it for this
  // long. continuousUpdates scanning re-reports the same nearby victim every
  // couple of seconds — without a cooldown, the Helper just kept re-acking
  // whichever device it saw first nonstop and never gave attention to any
  // other victim nearby.
  //
  // Re-acking is also the only moment the needsPull status characteristic
  // gets re-read — real-device timing showed a victim's flag flipping right
  // after an ack, but the Helper not noticing for up to the full 30s of this
  // cooldown, since that's the only thing gating the next read. Shortened
  // to bound that worst case without going back to "re-ack nonstop": still
  // long enough that 2 test devices' scan re-reports don't spam it.
  static const Duration _ackedCooldown = Duration(seconds: 12);

  String? deviceId;
  final Map<String, BluetoothDevice> _detectedVictims = {};
  // Per-victim ack bookkeeping — prevents piling up concurrent connect
  // attempts to the same device, and drives the retry-on-failure loop.
  final Set<String> _ackInFlight = {};
  final Map<String, int> _ackAttempts = {};
  final Map<String, Timer> _ackRetryTimers = {};
  final Map<String, DateTime> _ackedAt = {};
  // discoverPeers()+connect() can take longer than _ackedCooldown to
  // resolve — without this, a second ack for the same victim (cooldown
  // already expired) could fire a second, overlapping pull attempt while
  // the first is still mid-negotiation. Two concurrent WifiP2pManager calls
  // racing each other is a real, confirmed-on-hardware source of the
  // NO_GROUP/BUSY flakiness chased throughout this whole testing arc.
  final Set<String> _pullInFlight = {};
  // Same concurrency concern as _pullInFlight, for the Helper-to-Helper DTN
  // relay handshake (_attemptHelperRelay) instead of the Victim pull path.
  final Set<String> _relayInFlight = {};
  // Set around every discoverPeers()+connectToHelper() call this controller
  // makes itself (inside _attemptActivePull/_attemptHelperRelay) — guards the
  // reactive connectionFormedStream listener below against double-handling a
  // connection those methods are already explicitly processing.
  bool _explicitWifiDirectInFlight = false;
  bool _stopped = false;

  // Android can silently kill BLE scanning, BLE advertising, or the Wi-Fi
  // Direct accept-loop thread in the background on some OEMs — no error, no
  // callback, the radio just stops working. A Helper that looks "active" in
  // the UI but has actually gone deaf/invisible is exactly the kind of
  // silent failure this app can't afford, so this periodically checks all
  // three and restarts whichever one died.
  static const Duration _radioWatchdogInterval = Duration(seconds: 30);
  Timer? _radioWatchdog;

  StreamSubscription? _bleStatusSub;
  StreamSubscription? _wifiStatusSub;
  StreamSubscription? _dtnStatusSub;
  StreamSubscription<String>? _bundleReceivedSub;
  StreamSubscription<Map<String, dynamic>>? _connectionFormedSub;

  // Retries/in-flight BLE ops can still resolve after the screen disposes
  // and closes this controller — guard every emit so that race is a no-op
  // instead of "Bad state: Cannot add new events after calling close".
  void _emit(String line) {
    debugPrint('[Helper] $line');
    if (!_statusController.isClosed) _statusController.add(line);
  }

  Future<void> startHelperMode() async {
    try {
      // Defensive against a double-start (e.g. a rapid back-then-reopen on
      // the screen): without cancelling first, a second call leaked the old
      // subscriptions and left every event handled twice.
      await _cancelSubs();
      _stopped = false;

      deviceId = await _loadOrCreateDeviceId();
      _emit('Helper mode started (deviceId=$deviceId)');

      _bleStatusSub = bleManager.statusStream.listen(_emit);
      _wifiStatusSub = wifiDirectManager.statusStream.listen(_emit);
      _dtnStatusSub = dtnManager.statusStream.listen(_emit);
      _bundleReceivedSub = wifiDirectManager.bundleReceivedStream.listen(
        _onBundleJsonReceived,
      );

      await wifiDirectManager.startServer();
      // Clear any leftover P2P group from a previous mode this app run (e.g.
      // this device was a Victim — which is always an autonomous group owner
      // now — or the group-owner side of an earlier relay). A Helper must
      // start NOT a group owner: the deterministic relay election below may
      // elect it the *client*, and a device can't dial out as a client while
      // it's still a stale GO (an outbound socket from the GO role never works
      // on this hardware). createGroup() later re-forms one cheaply if this
      // device is instead elected the owner. disconnect() reliably removes any
      // group (native removeGroup retries past BUSY); when there's genuinely no
      // group it returns immediately after a single requestGroupInfo check.
      await wifiDirectManager.disconnect();
      // Helpers now also advertise (not just scan) — needed so a peer
      // Helper's scan can discover this device at all. Both Victims and
      // Helpers advertise the same service UUID; setRole (read over GATT
      // during the handshake below) is how a scanner tells which kind of
      // device it just found.
      await bleManager.setRole(bleRoleHelper);
      await bleManager.startAdvertising(deviceId!);
      // DTNManager's relay queue is in-memory only — it starts empty on every
      // fresh HelperController (a new mode-screen instance, e.g. after
      // switching Victim->Helper->Victim->Helper in one app run). Without
      // this, a bundle this device already carries (confirmed safely in
      // SQLite, just not yet synced to the backend) would be invisible to
      // the relay path even though it's still genuinely worth forwarding.
      final candidates = await repository.getUnsyncedBundles();
      for (final bundle in candidates) {
        dtnManager.onBundleReceived(bundle);
      }
      if (candidates.isNotEmpty) {
        _emit('Loaded ${candidates.length} bundle(s) from storage for relay');
      }
      // Also repaint the map/list with whatever's already in storage — the
      // bundleStream otherwise only emits when a NEW bundle arrives this
      // session, leaving the screen blank on a fresh Helper restart even
      // though this device is still carrying bundles from before.
      final all = await repository.getAllBundles();
      if (!_bundleController.isClosed) _bundleController.add(all);

      // Counterpart to VictimController's own reactive listener: a Victim's
      // groupOwnerIntent only biases negotiation, it doesn't guarantee an
      // outcome — confirmed on real hardware, a Victim's OWN connect() call
      // can leave it as group owner instead of this Helper. When that
      // happens this Helper becomes a Wi-Fi Direct *client* without ever
      // having called connect() itself, and nothing else would notice that
      // or fetch anything — the Victim was logging a false "transmitted"
      // success (it served its cached bundle straight back to itself)
      // while this Helper, the actual intended recipient, got nothing.
      wifiDirectManager.ensureListening();
      _connectionFormedSub = wifiDirectManager.connectionFormedStream.listen((
        info,
      ) async {
        if (_stopped || _explicitWifiDirectInFlight) return;
        final isGroupOwner = info['isGroupOwner'] as bool? ?? false;
        if (isGroupOwner) return;
        final groupOwnerAddress = info['groupOwnerAddress'] as String?;
        if (groupOwnerAddress == null) return;
        _emit(
          'Connection formed unexpectedly — pulling from $groupOwnerAddress',
        );
        final json = await wifiDirectManager.requestBundle(groupOwnerAddress);
        await wifiDirectManager.disconnect();
        if (_stopped) return;
        if (json == null || json.isEmpty) {
          _emit('Unexpected-connection pull returned nothing');
          return;
        }
        await _onBundleJsonReceived(json);
      });

      await bleManager.startScanning(_onPeerDetected);

      // Covers all three radios this mode depends on — Android can silently
      // kill any of them in the background (confirmed real for BLE scan on
      // some OEMs; the same risk applies to advertising and the WiFi Direct
      // accept-loop thread) with no callback, leaving the UI looking active
      // while the Helper is actually unreachable. Each check restarts only
      // the specific piece that died, not the whole mode.
      _radioWatchdog?.cancel();
      _radioWatchdog = Timer.periodic(_radioWatchdogInterval, (_) async {
        if (_stopped) return;
        if (!bleManager.isScanning) {
          _emit('BLE scan found stopped unexpectedly — restarting it');
          await bleManager.startScanning(_onPeerDetected);
        }
        if (_stopped) return;
        if (!await bleManager.isAdvertising()) {
          _emit('BLE advertising found stopped unexpectedly — restarting it');
          await bleManager.startAdvertising(deviceId!);
        }
        if (_stopped) return;
        if (!await wifiDirectManager.isServerRunning()) {
          _emit(
            'Wi-Fi Direct server found stopped unexpectedly — restarting it',
          );
          await wifiDirectManager.startServer();
        }
      });
    } catch (e) {
      _emit('Helper mode start failed: $e');
    }
  }

  Future<void> _cancelSubs() async {
    await _bleStatusSub?.cancel();
    await _wifiStatusSub?.cancel();
    await _dtnStatusSub?.cancel();
    await _bundleReceivedSub?.cancel();
    await _connectionFormedSub?.cancel();
  }

  /// BLE scanning can't tell Victims and peer Helpers apart before
  /// connecting — both advertise the same service UUID. Despite the name
  /// (kept from before peer-Helper detection existed; BLEManager's scan
  /// callback signature still calls this "victim" detection), this fires for
  /// either, and _attemptAck reads the peer's role over GATT to dispatch.
  void _onPeerDetected(String peerDeviceId, BluetoothDevice device, int rssi) {
    if (_stopped) return;
    _detectedVictims[peerDeviceId] = device;
    final ackedAt = _ackedAt[peerDeviceId];
    if (ackedAt != null && DateTime.now().difference(ackedAt) < _ackedCooldown)
      return;
    unawaited(_attemptAck(peerDeviceId, device, rssi));
  }

  /// Tries the GATT ACK write; on failure, retries with a short delay up to
  /// [_maxAckAttempts] times. [_ackInFlight] stops a second detection of the
  /// same victim (re-scan, or a repeat advertisement) from starting a second
  /// concurrent connect/write attempt on top of one already running — without
  /// this, the BLE handshake never got a second chance after a single failed
  /// write, which is why a Victim could be stuck forever on "No Helper ACKs
  /// received in RSSI window" even though the Helper had detected it fine.
  Future<void> _attemptAck(
    String victimDeviceId,
    BluetoothDevice device,
    int rssi,
  ) async {
    if (_stopped || _ackInFlight.contains(victimDeviceId)) return;
    _ackInFlight.add(victimDeviceId);

    final attempt = (_ackAttempts[victimDeviceId] ?? 0) + 1;
    _ackAttempts[victimDeviceId] = attempt;
    final result = await bleManager.sendRssiAck(device, rssi);
    _ackInFlight.remove(victimDeviceId);
    if (_stopped) return;

    if (result.success) {
      _ackAttempts.remove(victimDeviceId);
      _ackedAt[victimDeviceId] = DateTime.now();
      if (result.role == bleRoleHelper) {
        // Not actually a Victim — a peer Helper found via the same BLE scan.
        // Don't run the Victim pull-mode logic against it; do a DTN relay
        // handshake instead. result.peerDeviceId is the peer's app-UUID (read
        // over GATT just now) — the input to the deterministic group-owner
        // election that stops both Helpers from connect()-ing at once.
        unawaited(
          _attemptHelperRelay(victimDeviceId, peerAppUuid: result.peerDeviceId),
        );
        return;
      }
      if (result.needsPull) {
        // This victim's chipset can't initiate Wi-Fi Direct itself — don't
        // block the ack bookkeeping on the pull attempt, just kick it off.
        unawaited(_attemptActivePull(victimDeviceId));
      }
      return;
    }
    if (attempt >= _maxAckAttempts) {
      _emit(
        'Giving up on GATT ACK to $victimDeviceId after $attempt attempts — will retry if it is seen again.',
      );
      _ackAttempts.remove(victimDeviceId);
      return;
    }
    _emit(
      'Will retry GATT ACK to $victimDeviceId (attempt ${attempt + 1}/$_maxAckAttempts)…',
    );
    // Re-add to _ackInFlight immediately so a re-detection in the meantime
    // doesn't start a second attempt while this retry is pending.
    _ackInFlight.add(victimDeviceId);
    _ackRetryTimers[victimDeviceId]?.cancel();
    _ackRetryTimers[victimDeviceId] = Timer(_ackRetryDelay, () {
      _ackRetryTimers.remove(victimDeviceId);
      _ackInFlight.remove(victimDeviceId);
      if (!_stopped) unawaited(_attemptAck(victimDeviceId, device, rssi));
    });
  }

  /// Counterpart to the normal "Victim pushes, Helper just listens" flow —
  /// used when the Victim flagged needsPull (its chipset can't reliably
  /// initiate P2P discovery itself). The Helper does the discovering and
  /// connecting instead.
  ///
  /// groupOwnerIntent only biases who becomes P2P group owner, it doesn't
  /// guarantee it — confirmed on real hardware where the connecting side
  /// (Helper, here) still ended up group owner. So after connect() succeeds,
  /// this checks its OWN resulting role rather than assuming "I connected,
  /// therefore I'm the client": if Helper ended up the client, it actively
  /// fetches the bundle; if it ended up group owner instead, the Victim
  /// learns that reactively (via its own connectionFormedStream listener)
  /// and pushes into Helper's already-running normal server instead — same
  /// path bundleReceivedStream always uses, no extra code needed here.
  Future<void> _attemptActivePull(String victimDeviceId) async {
    if (_stopped || !_pullInFlight.add(victimDeviceId)) return;
    _explicitWifiDirectInFlight = true;
    try {
      _emit(
        'Connecting to $victimDeviceId (it cannot self-initiate Wi-Fi Direct)',
      );
      final peers = await wifiDirectManager.discoverPeers();
      if (_stopped) return;
      if (peers.isEmpty) {
        _emit(
          'No Wi-Fi Direct peers discovered while connecting to $victimDeviceId',
        );
        // Confirmed on real hardware: a stuck/stale P2P discovery state
        // (left over from a previous app run, or just bad luck) can keep
        // returning 0 peers forever — nothing else in this path ever calls
        // disconnect()/stopPeerDiscovery() to reset it, since that's
        // normally only done after a connect attempt, not after discovery
        // itself comes up empty. Without this, every later attempt just
        // compounds the same stuck state instead of getting a fresh shot.
        await wifiDirectManager.disconnect();
        return;
      }
      // Same first-peer simplification as the push path — fine for the 2
      // test devices this is verified against; see discoverPeers() docs.
      final peerAddress = peers.first['deviceAddress'] as String;
      final connectionInfo = await wifiDirectManager.connectToHelper(
        peerAddress,
        myDeviceId: deviceId ?? '',
      );
      if (_stopped) return;
      if (connectionInfo == null) {
        _emit('Could not connect to Wi-Fi Direct peer $victimDeviceId');
        // Confirmed on real hardware: a failed connect() (NO_GROUP) can leave
        // the P2P stack mid-negotiation, and the very next discoverPeers()
        // call comes back BUSY (reason=2) as a result. Clean up before the
        // next retry instead of leaving that for the next attempt to collide
        // with.
        await wifiDirectManager.disconnect();
        return;
      }
      final isGroupOwner = connectionInfo['isGroupOwner'] as bool? ?? false;
      if (isGroupOwner) {
        // Helper ended up GO, not client — can't dial out to fetch (that
        // address would be itself). The Victim's own broadcast listener will
        // notice it's the client and push into this device's running server.
        _emit(
          'Connected to $victimDeviceId as group owner — waiting for it to push',
        );
        return;
      }
      final groupOwnerAddress = connectionInfo['groupOwnerAddress'] as String;
      final json = await wifiDirectManager.requestBundle(groupOwnerAddress);
      await wifiDirectManager.disconnect();
      if (_stopped) return;
      if (json == null || json.isEmpty) {
        _emit('Pull from $victimDeviceId returned nothing');
        return;
      }
      await _onBundleJsonReceived(json);
    } finally {
      _explicitWifiDirectInFlight = false;
      _pullInFlight.remove(victimDeviceId);
    }
  }

  /// Mirrors _attemptActivePull's structure, but for a peer Helper instead
  /// of a pull-mode Victim: discover/connect over Wi-Fi Direct, then hand
  /// off to DTNManager.relayMissing, which asks the peer's manifest first
  /// and only pushes what it's missing.
  ///
  /// [peerAppUuid] is the peer Helper's app-UUID, read over GATT during the
  /// ack. It drives a deterministic Wi-Fi Direct group-owner election that is
  /// the fix for the Helper-Helper "glare" failure: previously BOTH Helpers
  /// ran discoverPeers()+connect() toward each other within a fraction of a
  /// second, so the two group-owner negotiations collided and neither group
  /// ever formed (confirmed on real hardware: 14x groupFormed=false →
  /// NO_GROUP on one side, CONNECT_FAILED reason=2 BUSY on the other, every
  /// single contact). Now exactly ONE side acts: the device with the
  /// lexicographically-lower UUID becomes an autonomous group owner
  /// (createGroup — the same passive-GO role a Victim uses, the only Wi-Fi
  /// Direct configuration proven 100% reliable on this hardware) and just
  /// waits; the higher-UUID side is the sole connector and drives the
  /// bidirectional sync. No two simultaneous connect()s, so no glare.
  Future<void> _attemptHelperRelay(
    String peerHelperDeviceId, {
    String? peerAppUuid,
  }) async {
    if (_stopped || !_relayInFlight.add(peerHelperDeviceId)) return;
    _explicitWifiDirectInFlight = true;
    try {
      // Deterministic group-owner election. Only possible when the peer's
      // app-UUID was actually read over GATT (older builds / a failed read
      // leave it null) — in that case fall through to the legacy "both
      // actively discover + connect jitter" path, which still works most of
      // the time and is no worse than before this election existed.
      final myUuid = deviceId;
      if (peerAppUuid != null &&
          myUuid != null &&
          peerAppUuid != myUuid &&
          myUuid.compareTo(peerAppUuid) < 0) {
        // Lower UUID → passive group owner. createGroup makes this device a
        // discoverable soft-AP at 192.168.49.1; the peer (higher UUID)
        // discovers it, joins as the sole client, and its sync() pushes its
        // bundles into this device's already-running server (received via
        // bundleReceivedStream) AND pulls this device's bundles back — the
        // whole exchange rides the client's one connection, so this side
        // never has to dial out (which never works from the GO role on this
        // hardware). Idempotent: createGroup reuses an existing group, so
        // re-running on the next contact is a cheap no-op.
        // ponytail: while holding this GO group the device can't also dial
        // out to pull a needsPull Victim (you can't be a client to another GO
        // while you're a GO). Harmless for the 2-Helper relay test (no Victim
        // present); revisit with ephemeral teardown if a single device must
        // serve Victims AND peer Helpers concurrently in a 3+ device mesh.
        final ok = await wifiDirectManager.createGroup();
        _emit(
          ok
              ? 'Elected Wi-Fi Direct group owner for relay with '
                    '$peerHelperDeviceId — waiting for it to sync'
              : 'createGroup failed for relay with $peerHelperDeviceId — '
                    'will retry on next contact',
        );
        return;
      }

      // Higher UUID (or no UUID available) → active side: discover the peer,
      // connect as client, and relay. No early-return for an empty
      // storedBundles — DTNManager.sync pulls from the peer in the same
      // contact, worth doing even with nothing of our own to push.
      if (peerAppUuid != null && myUuid != null && peerAppUuid != myUuid) {
        _emit(
          'Found peer Helper $peerHelperDeviceId — connecting as client '
          '(group-owner election: peer is the group owner)',
        );
        // The elected client must own NO P2P group before it dials in. If this
        // device is still a stale group owner (a Victim-era autonomous group,
        // or a previous relay's), connect() is a silent no-op — it stays GO,
        // and two group owners can never join, so the relay deadlocks
        // (confirmed on real hardware: every HH contact resolved to
        // isGroupOwner=true and sat passively forever). disconnect() now
        // reliably tears down any owned group (removeGroup retries past BUSY in
        // the native layer), so after this the connect() below joins the peer's
        // autonomous group as a true client — byte-for-byte the proven
        // Victim->Helper pull path. Doing it here, per contact, also makes the
        // client self-recover if it somehow re-acquired a group mid-session,
        // rather than relying solely on the one-shot cleanup at mode start.
        await wifiDirectManager.disconnect();
        if (_stopped) return;
      } else {
        // No UUID to elect on — legacy mutually-active path. The deterministic
        // connect jitter in connectToHelper is the only glare mitigation here.
        _emit('Found peer Helper $peerHelperDeviceId — attempting DTN relay');
      }
      final peers = await wifiDirectManager.discoverPeers();
      if (_stopped) return;
      if (peers.isEmpty) {
        _emit(
          'No Wi-Fi Direct peers discovered while relaying to $peerHelperDeviceId',
        );
        // See _attemptActivePull's identical call for why — a stuck
        // discovery state never gets reset on this path otherwise.
        await wifiDirectManager.disconnect();
        return;
      }
      final peerAddress = peers.first['deviceAddress'] as String;
      final connectionInfo = await wifiDirectManager.connectToHelper(
        peerAddress,
        myDeviceId: deviceId ?? '',
      );
      if (_stopped) return;
      if (connectionInfo == null) {
        _emit('Could not connect to Wi-Fi Direct peer $peerHelperDeviceId');
        await wifiDirectManager.disconnect();
        return;
      }
      final isGroupOwner = connectionInfo['isGroupOwner'] as bool? ?? false;
      if (isGroupOwner) {
        // This device can't reliably dial out as group owner (see the
        // removed "known address" shortcut's doc above) — wait instead.
        // The peer is scanning too and will connect to this device's
        // server on its own next contact, and its sync() call covers both
        // directions, so nothing is lost by this device doing nothing here.
        _emit(
          'Connected to $peerHelperDeviceId as group owner — will relay once it contacts this device first',
        );
        return;
      }
      final groupOwnerAddress = connectionInfo['groupOwnerAddress'] as String;
      await _savePulledBundles(
        await dtnManager.relayMissing(groupOwnerAddress, peerHelperDeviceId),
      );
      await wifiDirectManager.disconnect();
    } finally {
      _explicitWifiDirectInFlight = false;
      _relayInFlight.remove(peerHelperDeviceId);
    }
  }

  /// Persists bundles DTNManager.relayMissing pulled from a peer (already
  /// added to its own storedBundles for further relay) and repaints the
  /// map/list — the SQLite save and bundleStream update DTNManager itself
  /// has no access to.
  Future<void> _savePulledBundles(List<DistressBundleModel> bundles) async {
    if (bundles.isEmpty) return;
    for (final bundle in bundles) {
      _emit('Bundle received: ${bundle.bundleId}');
      await repository.saveBundle(bundle);
    }
    final all = await repository.getAllBundles();
    if (!_bundleController.isClosed) _bundleController.add(all);
  }

  Future<void> _onBundleJsonReceived(String json) async {
    try {
      final decoded = jsonDecode(json);
      // A relay batch from another Helper (DTNManager.relayMissing) arrives as
      // a JSON array; a single Victim push/pull arrives as a JSON object —
      // the two paths share this same native transport and event, so the
      // shape of the decoded JSON is what tells them apart.
      final bundleMaps = decoded is List
          ? decoded.cast<Map<String, dynamic>>()
          : [decoded as Map<String, dynamic>];
      for (final map in bundleMaps) {
        final bundle = DistressBundleModel.fromJson(map);
        _emit('Bundle received: ${bundle.bundleId}');
        await repository.saveBundle(bundle);
        dtnManager.onBundleReceived(bundle);
      }
      final all = await repository.getAllBundles();
      if (!_bundleController.isClosed) _bundleController.add(all);
    } catch (e) {
      _emit('Failed to process received bundle: $e');
    }
  }

  Future<String> _loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(deviceIdPrefKey);
    if (existing != null) return existing;
    final generated = const Uuid().v4();
    await prefs.setString(deviceIdPrefKey, generated);
    return generated;
  }

  Future<void> stopHelperMode() async {
    try {
      _stopped = true;
      _radioWatchdog?.cancel();
      for (final timer in _ackRetryTimers.values) {
        timer.cancel();
      }
      _ackRetryTimers.clear();
      _pullInFlight.clear();
      _relayInFlight.clear();
      _explicitWifiDirectInFlight = false;
      await bleManager.stopScanning();
      await bleManager.stopAdvertising();
      await wifiDirectManager.stopServer();
      await _cancelSubs();
      _emit('Helper mode stopped');
    } catch (e) {
      _emit('Helper mode stop failed: $e');
    }
  }

  void dispose() {
    _radioWatchdog?.cancel();
    _connectionFormedSub?.cancel();
    bleManager.dispose();
    wifiDirectManager.dispose();
    dtnManager.dispose();
    _statusController.close();
    _bundleController.close();
  }
}
