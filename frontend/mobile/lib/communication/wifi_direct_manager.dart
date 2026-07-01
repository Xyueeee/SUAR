import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants.dart';

/// Wi-Fi Direct has no mature Flutter plugin, so P2P negotiation and the
/// transfer socket both live in native Android (MainActivity.kt) behind the
/// "suar/wifi_direct" MethodChannel, per CLAUDE.md prompt instructions.
class WiFiDirectManager {
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  // Jitter before connect() — see connectToHelper's docs. Per-instance,
  // not per-call, so the random delays aren't generated from the same
  // tightly-clustered seed across rapid retries.
  final _glareJitter = Random();

  // Mirrored to logcat too — a logcat dump alone used to be unable to show
  // any of this, only the in-app activity card could.
  void _emit(String line) {
    debugPrint('[WiFiDirect] $line');
    if (!_statusController.isClosed) _statusController.add(line);
  }

  static const MethodChannel _channel = MethodChannel(wifiDirectChannel);
  static const EventChannel _events = EventChannel(
    '${wifiDirectChannel}_events',
  );

  StreamSubscription? _eventSub;
  final _bundleReceivedController = StreamController<String>.broadcast();
  final _connectionFormedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _bundleDeliveredController = StreamController<void>.broadcast();

  /// Raw bundle JSON strings received by the native ServerSocket.
  Stream<String> get bundleReceivedStream => _bundleReceivedController.stream;

  /// Fires when this device's native server answered a "pull" with a non-empty
  /// bundle — i.e. a nearby device actually fetched what this (passive
  /// group-owner) device was holding. Lets a Victim that is waiting to be
  /// pulled show a real "picked up" confirmation instead of sitting silent.
  Stream<void> get bundleDeliveredStream => _bundleDeliveredController.stream;

  /// Fires whenever a P2P group forms, on EITHER end, regardless of which
  /// side called connect() — driven by WIFI_P2P_CONNECTION_CHANGED_ACTION.
  /// {isGroupOwner, groupOwnerAddress} are both from THIS device's own
  /// perspective. Needed because groupOwnerIntent only biases negotiation,
  /// it doesn't guarantee an outcome — confirmed on real hardware where the
  /// connecting side still ended up group owner.
  Stream<Map<String, dynamic>> get connectionFormedStream =>
      _connectionFormedController.stream;

  /// Registers the EventChannel listener without requiring a discoverPeers()/
  /// startServer() call first — needed by a device sitting passively in pull
  /// mode, which does neither, but still needs to react to connectionFormed.
  void ensureListening() => _ensureEventListener();

  void _ensureEventListener() {
    _eventSub ??= _events.receiveBroadcastStream().listen((event) {
      final map = Map<String, dynamic>.from(event as Map);
      switch (map['event']) {
        case 'bundleReceived':
          _bundleReceivedController.add(map['json'] as String);
          _emit('Bundle received over Wi-Fi Direct');
        case 'bundleDelivered':
          if (!_bundleDeliveredController.isClosed) {
            _bundleDeliveredController.add(null);
          }
          _emit('A nearby device fetched the cached bundle');
        case 'connectionFormed':
          _connectionFormedController.add(map);
        case 'debugLog':
          _emit(map['message'] as String);
      }
    });
  }

  /// Android has no public API to correlate a WiFi P2P peer with the BLE
  /// deviceId that selected it. With exactly 2 test devices (CLAUDE.md
  /// Section 4) this just picks the first discovered peer; revisit if
  /// testing ever needs 3+ simultaneous Helpers.
  ///
  /// Set true only when the native call genuinely completed its full poll
  /// and still found nothing — distinct from a thrown PlatformException
  /// (LOCATION_DISABLED, P2P_DISABLED, PERMISSION_DENIED etc), which is a
  /// separate, already-surfaced config problem and should NOT count as
  /// evidence that this device's chipset can't initiate P2P discovery.
  bool lastDiscoveryGenuinelyEmpty = false;

  Future<List<Map<String, dynamic>>> discoverPeers({
    bool isRetry = false,
  }) async {
    try {
      // The Victim side never calls startServer(), so without this the
      // native debugLog events fired during discovery have no listener and
      // are silently dropped (eventSink stays null until something
      // subscribes to the EventChannel).
      _ensureEventListener();
      final result = await _channel.invokeMethod('discoverPeers');
      final peers = (result as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      lastDiscoveryGenuinelyEmpty = peers.isEmpty;
      _emit('Discovered ${peers.length} Wi-Fi Direct peer(s)');
      return peers;
    } catch (e) {
      lastDiscoveryGenuinelyEmpty = false;
      _emit('Peer discovery failed: $e');
      // BUSY (reason=2) means the P2P framework is still processing a
      // previous request (e.g. the teardown from the last contact) — not
      // "no peers nearby". Confirmed on real hardware: this clears within
      // about a second on its own. One retry here means a single transient
      // BUSY doesn't waste this entire relay/pull attempt and force a wait
      // for the next BLE contact cycle (~15s) just to try again.
      if (!isRetry &&
          e is PlatformException &&
          e.message?.contains('reason=2') == true) {
        await Future.delayed(const Duration(milliseconds: 800));
        return discoverPeers(isRetry: true);
      }
      return [];
    }
  }

  Future<Map<String, dynamic>?> connectToHelper(
    String deviceAddress, {
    String myDeviceId = '',
    bool isRetry = false,
    bool skipGlareJitter = false,
  }) async {
    try {
      // Both ends of a contact run their OWN discover+connect cycle
      // independently (each device's BLE detection timer drives it,
      // with zero coordination between devices) — when both happen to
      // call connect() toward each other at nearly the same moment, P2P
      // group-owner negotiation gets a real, documented "glare" conflict
      // and the group never forms (NO_GROUP). A previous assumption here
      // blamed an unaccepted "Allow Wi-Fi Direct connection?" system
      // prompt instead — directly disproven on real hardware (no such
      // prompt appears at all in this app's testing).
      //
      // A pure-random 50-450ms jitter was tried first and confirmed
      // insufficient on real hardware: 3 consecutive NO_GROUP glare
      // failures in a row, each costing a full ~14s connectionInfo poll —
      // both devices' BLE-driven contact timing is synchronized within
      // ~100-300ms of each other, barely inside that window, so re-rolling
      // dice each retry can keep landing on a collision. A deterministic
      // delay derived from this device's OWN id (when known) fixes that:
      // for any given pair of devices it consistently makes ONE side dial
      // sooner and the other later, the SAME way on every retry, instead
      // of leaving it to chance each time. A small random component stays
      // on top only to break the rare case where two ids hash close
      // together. Falls back to pure jitter if no id was supplied (kept
      // backward-compatible for callers that don't have one yet).
      //
      // skipGlareJitter short-circuits all of the above: the Helper-Helper
      // relay now runs a deterministic group-owner election (see
      // HelperController._attemptHelperRelay), so exactly ONE side ever calls
      // connect() — there is no second connector to glare against. The anti-
      // glare delay (up to ~2.3s) is then pure wasted latency on every single
      // relay contact, which was the main reason HH felt slow. Only the legacy
      // no-election fallback path still needs the jitter.
      if (!skipGlareJitter) {
        final deterministicMs = myDeviceId.isEmpty
            ? 0
            : myDeviceId.hashCode.abs() % 2000;
        final jitterMs = 50 + _glareJitter.nextInt(300);
        await Future.delayed(
          Duration(milliseconds: deterministicMs + jitterMs),
        );
      }
      _emit('Connecting to $deviceAddress');
      final result = await _channel.invokeMethod('connect', {
        'deviceAddress': deviceAddress,
      });
      final info = Map<String, dynamic>.from(result as Map);
      _emit(
        'Wi-Fi Direct connected: groupOwnerAddress=${info['groupOwnerAddress']} '
        'isGroupOwner=${info['isGroupOwner']}',
      );
      return info;
    } catch (e) {
      _emit('Wi-Fi Direct connect failed: $e');
      if (e is PlatformException && e.code == 'NO_GROUP') {
        // Confirmed on real hardware this isn't always mutual glare: logs
        // showed cases where this device alone called connect() for the
        // full 14s poll while the peer's own discoverPeers() never found
        // this device at all (one-sided negotiation, not a collision) —
        // a known flaky-discovery limitation on the budget test chipset.
        _emit(
          'Could not pair with the peer in time. Wi-Fi Direct negotiation '
          'did not complete (either a connect() collision or one-sided '
          'discovery flakiness). The next contact attempt will retry.',
        );
      }
      // Originally only retried on BUSY (reason=2), but real-hardware logs
      // also showed a bare reason=0 (WifiP2pManager.ActionListener's generic
      // ERROR) on a single attempt with no other symptoms — the very next
      // contact cycle (~15-30s later) then succeeded normally, so this was
      // transient too, not a real rejection. Retrying on any CONNECT_FAILED
      // reason costs one cheap 800ms wait instead of a whole wasted cycle.
      if (!isRetry && e is PlatformException && e.code == 'CONNECT_FAILED') {
        await Future.delayed(const Duration(milliseconds: 800));
        return connectToHelper(
          deviceAddress,
          myDeviceId: myDeviceId,
          isRetry: true,
          skipGlareJitter: skipGlareJitter,
        );
      }
      return null;
    }
  }

  Future<bool> sendBundle(
    String groupOwnerAddress,
    Map<String, dynamic> bundleJson,
  ) => sendRawJson(groupOwnerAddress, jsonEncode(bundleJson));

  /// Underlying transport for [sendBundle] — the native side just relays
  /// bytes and doesn't care whether the JSON is a single bundle object (the
  /// Victim push/pull path) or an array of bundles (DTN relay between
  /// Helpers, see DTNManager.relayAllTo), so both reuse this directly.
  Future<bool> sendRawJson(String groupOwnerAddress, String rawJson) async {
    try {
      await _channel.invokeMethod('sendBundle', {
        'address': groupOwnerAddress,
        'json': rawJson,
      });
      _emit('Bundle sent over Wi-Fi Direct');
      return true;
    } catch (e) {
      _emit('Bundle send failed: $e');
      return false;
    }
  }

  Future<void> startServer() async {
    try {
      _ensureEventListener();
      await _channel.invokeMethod('startServer');
      _emit('Wi-Fi Direct server listening on port $wifiDirectPort');
    } catch (e) {
      _emit('Start server failed: $e');
    }
  }

  /// Caches the local bundle JSON natively so the server can answer a
  /// "pull" request with it — used when this device can't initiate Wi-Fi
  /// Direct itself, so a Helper has to come fetch it instead of waiting to
  /// be pushed one. Pass null to clear.
  Future<void> setLocalBundle(Map<String, dynamic>? bundleJson) async {
    try {
      await _channel.invokeMethod('setLocalBundle', {
        'json': bundleJson == null ? null : jsonEncode(bundleJson),
      });
    } catch (e) {
      _emit('setLocalBundle failed: $e');
    }
  }

  /// Active-pull counterpart to the push flow — connects to [address] and
  /// asks it to send its cached bundle back, instead of waiting to be pushed
  /// one. Returns the raw bundle JSON string, or null on failure.
  Future<String?> requestBundle(String address) async {
    try {
      _ensureEventListener();
      final json = await _channel.invokeMethod('requestBundle', {
        'address': address,
      });
      _emit('Pulled bundle over Wi-Fi Direct');
      return json as String?;
    } catch (e) {
      _emit('Bundle pull failed: $e');
      return null;
    }
  }

  /// Caches the bundleIds this device currently holds natively, so the
  /// server can answer a "manifest" request without round-tripping back to
  /// Dart — kept in sync by DTNManager whenever its stored-bundle set
  /// changes (received, loaded from storage). Pass an empty list to clear.
  Future<void> setManifest(List<String> bundleIds) async {
    try {
      await _channel.invokeMethod('setManifest', {'ids': bundleIds});
    } catch (e) {
      _emit('setManifest failed: $e');
    }
  }

  /// Asks the peer at [address] which bundleIds it already holds — lets the
  /// caller (DTNManager.relayMissing) send only what's actually missing
  /// instead of blindly re-sending everything on every Helper-Helper
  /// contact. Returns an empty list on failure (treated the same as "peer
  /// has nothing", so the caller just sends everything — same fallback
  /// behaviour as before this existed).
  Future<List<String>> requestManifest(String address) async {
    try {
      final result = await _channel.invokeMethod('requestManifest', {
        'address': address,
      });
      return (result as List).cast<String>();
    } catch (e) {
      _emit('Manifest request failed: $e');
      return [];
    }
  }

  /// Caches the full bundle objects this device is carrying for relay
  /// natively, so the server can answer a "sync" request's pull half
  /// without round-tripping to Dart — kept in sync by DTNManager alongside
  /// setManifest() whenever its stored-bundle set changes.
  Future<void> setRelayBundles(String bundlesJson) async {
    try {
      await _channel.invokeMethod('setRelayBundles', {'json': bundlesJson});
    } catch (e) {
      _emit('setRelayBundles failed: $e');
    }
  }

  /// Pushes [pushPayloadJson] (bundles this device has that the peer at
  /// [address] doesn't, already computed by the caller via
  /// requestManifest) AND pulls whatever the peer has that this device
  /// doesn't (computed on the peer's side from [ownBundleIds]) — all
  /// within the single connection this device opens as the Wi-Fi Direct
  /// client. See WifiDirectHelper.connectClientSocket's docs: the group
  /// owner's outbound socket has never reliably worked on test hardware,
  /// so folding both directions into the client's own connection is what
  /// lets the GO side of a relay happen at all. Returns the peer's
  /// returned bundles as a raw JSON array string (possibly "[]"), or null
  /// on failure.
  Future<String?> sync(
    String address,
    List<String> ownBundleIds,
    String pushPayloadJson,
  ) async {
    try {
      final result = await _channel.invokeMethod('sync', {
        'address': address,
        'ownIds': ownBundleIds,
        'payload': pushPayloadJson,
      });
      return result as String?;
    } catch (e) {
      _emit('Sync failed: $e');
      return null;
    }
  }

  /// Lets a watchdog notice if the native accept-loop thread died and
  /// restart it instead of looking active while actually unreachable.
  /// Defaults to true on failure — same fail-open reasoning as
  /// BLEManager.isAdvertising.
  Future<bool> isServerRunning() async {
    try {
      final result = await _channel.invokeMethod('isServerRunning');
      return result as bool? ?? true;
    } catch (e) {
      // Fail-open is intentional (see doc above) — but a silent catch here
      // meant a broken platform channel looked identical to "server is
      // fine," so the watchdog calling this would never even know to
      // suspect it. Logging doesn't change the fail-open behavior, just
      // makes a real break visible instead of indistinguishable from healthy.
      _emit('isServerRunning check failed: $e');
      return true;
    }
  }

  Future<void> stopServer() async {
    try {
      await _channel.invokeMethod('stopServer');
      _emit('Wi-Fi Direct server stopped');
    } catch (e) {
      _emit('Stop server failed: $e');
    }
  }

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      _emit('Wi-Fi Direct disconnected');
    } catch (e) {
      _emit('Disconnect failed: $e');
    }
  }

  /// Makes this device an autonomous Wi-Fi Direct group owner (soft-AP at
  /// 192.168.49.1) so it's actually discoverable by a peer's discoverPeers()
  /// — a device that only opened the transfer ServerSocket without a P2P
  /// group is invisible to discovery (confirmed on real hardware: Helper
  /// found 0 peers forever against a purely-passive Victim). The joiner is
  /// always the client, dialing into this device's already-running server.
  /// Returns false on failure so the caller can fall back / retry.
  Future<bool> createGroup() async {
    try {
      await _channel.invokeMethod('createGroup');
      _emit('Now an autonomous Wi-Fi Direct group owner (discoverable)');
      return true;
    } catch (e) {
      _emit('createGroup failed: $e');
      return false;
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _statusController.close();
    _bundleReceivedController.close();
    _connectionFormedController.close();
    _bundleDeliveredController.close();
  }

  /// Whether the device's regular Wi-Fi (station mode) is currently
  /// associated to an access point — a real, confirmed-on-hardware cause of
  /// unreliable/failed Wi-Fi Direct peer discovery and connection. Static and
  /// decoupled from any controller instance so RadioStatusBanner can poll it
  /// without needing a live Victim/Helper session.
  static Future<Map<String, dynamic>?> getStaInfo() async {
    try {
      final result = await _channel.invokeMethod('getStaInfo');
      return Map<String, dynamic>.from(result as Map);
    } catch (_) {
      return null;
    }
  }

  /// Pushes [text] into the persistent foreground notification — visible in
  /// the notification shade/lock screen even with the app backgrounded or
  /// the screen off, unlike an in-app banner which only helps if someone is
  /// currently looking at that exact device's screen. Safe to call
  /// repeatedly; it just refreshes the already-running notification.
  ///
  /// [text] is the short collapsed line; [detail], when given, is the longer
  /// plain-language explanation shown when the user expands the notification
  /// (Android BigTextStyle) — keeps the collapsed notification one tidy line
  /// instead of a wall of text. [wifiAction] adds a one-tap "Wi-Fi settings"
  /// button so a radio problem can be fixed straight from the shade without
  /// opening the app.
  static Future<void> updateMeshStatus(
    String text, {
    String? detail,
    bool wifiAction = false,
  }) async {
    try {
      await _channel.invokeMethod('updateMeshStatus', {
        'text': text,
        'detail': detail,
        'wifiAction': wifiAction,
      });
    } catch (_) {
      // Best-effort — a stale notification isn't worth surfacing an error for.
    }
  }

  static Future<void> openWifiSettings() async {
    try {
      await _channel.invokeMethod('openWifiSettings');
    } catch (_) {
      // Best-effort — nothing to do if the platform can't open it.
    }
  }

  /// Sets the Wi-Fi Direct device name this phone broadcasts — the label the
  /// other phone sees in its "Allow Wi-Fi Direct connection?" prompt. A neutral
  /// role-tagged name like "Helper-1A2B" / "SOS-1A2B" makes that prompt both
  /// understandable (clearly a SUAR peer) and anonymous (hides the real model/
  /// owner name). Best-effort: the underlying API is hidden and may be blocked
  /// on newer Android, in which case the prompt just keeps the default name.
  Future<void> setP2pDeviceName(String name) async {
    try {
      await _channel.invokeMethod('setDeviceName', {'name': name});
    } catch (e) {
      _emit('setP2pDeviceName failed: $e');
    }
  }
}
