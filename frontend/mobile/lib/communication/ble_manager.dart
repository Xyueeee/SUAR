import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants.dart';

/// Wraps both BLE roles described in CLAUDE.md Section 11 (1.x):
/// - Helper (central): scan for Victim beacons, write RSSI ACK as a GATT client.
///   Backed by flutter_blue_plus, which fully supports the central role.
/// - Victim (peripheral): advertise + host a GATT server for the ACK characteristic.
///   flutter_blue_plus has no peripheral API, so this delegates to native Android
///   via MethodChannel/EventChannel (see MainActivity.kt).
class BLEManager {
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  static const MethodChannel _peripheralChannel = MethodChannel(
    blePeripheralChannel,
  );
  static const EventChannel _peripheralEvents = EventChannel(
    blePeripheralEventChannel,
  );
  StreamSubscription? _peripheralEventSub;

  final _helperAckController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emits {helperDeviceId, rssi} each time a Helper writes its GATT ACK.
  Stream<Map<String, dynamic>> get helperAckStream =>
      _helperAckController.stream;

  StreamSubscription<List<ScanResult>>? _scanSub;

  // BLE operations (connect/discover/write) run for real wall-clock time —
  // a screen can be disposed (closing these controllers) while one is still
  // in flight. Guarding every emit against isClosed turned a guaranteed
  // crash ("Bad state: Cannot add new events after calling close") into a
  // harmless no-op for whichever in-flight call loses that race.
  void _emit(String line) {
    debugPrint('[BLE] $line');
    if (!_statusController.isClosed) _statusController.add(line);
  }

  Future<void> startAdvertising(String deviceId) async {
    try {
      _peripheralEventSub ??= _peripheralEvents.receiveBroadcastStream().listen((
        event,
      ) {
        final ack = Map<String, dynamic>.from(event as Map);
        if (!_helperAckController.isClosed) _helperAckController.add(ack);
        _emit(
          'GATT ACK received from ${ack['helperDeviceId']} rssi=${ack['rssi']}',
        );
      });
      await _peripheralChannel.invokeMethod('startAdvertising', {
        'deviceId': deviceId,
      });
      _emit('BLE advertising started (deviceId=$deviceId)');
    } catch (e) {
      _emit('BLE advertising failed: $e');
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _peripheralChannel.invokeMethod('stopAdvertising');
      _emit('BLE advertising stopped');
    } catch (e) {
      _emit('Stop advertising failed: $e');
    }
  }

  /// Tells the GATT status characteristic whether this device's chipset has
  /// been found unable to initiate Wi-Fi Direct discovery — read by Helpers
  /// over the same brief connection used for the RSSI ack.
  Future<void> setNeedsPull(bool value) async {
    try {
      await _peripheralChannel.invokeMethod('setNeedsPull', {'value': value});
    } catch (e) {
      _emit('setNeedsPull failed: $e');
    }
  }

  /// Tells the GATT status characteristic this device's current Dart-side
  /// role (bleRoleVictim/bleRoleHelper) — read by whoever connects so they
  /// know whether they just found a distressed Victim or a peer Helper.
  Future<void> setRole(int role) async {
    try {
      await _peripheralChannel.invokeMethod('setRole', {'value': role});
    } catch (e) {
      _emit('setRole failed: $e');
    }
  }

  /// Tells the GATT status characteristic whether this device's regular Wi-Fi
  /// is currently joined to an access point — read by whoever connects so the
  /// pair can pick the AP-joined side to host the Wi-Fi Direct group (the only
  /// side a single-radio chipset can reach across a channel mismatch). Refreshed
  /// periodically by the controllers, since association can change mid-session.
  Future<void> setAssociated(bool value) async {
    try {
      await _peripheralChannel.invokeMethod('setAssociated', {'value': value});
    } catch (e) {
      _emit('setAssociated failed: $e');
    }
  }

  /// Lets a watchdog notice if native BLE advertising silently died (some
  /// OEMs are known to kill background BLE activity with no callback) and
  /// restart it instead of looking active while actually invisible to
  /// anyone scanning. Defaults to true on failure — if we can't even ask,
  /// assume it's fine rather than restarting in a loop against a transient
  /// channel error.
  Future<bool> isAdvertising() async {
    try {
      final result = await _peripheralChannel.invokeMethod('isAdvertising');
      return result as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Lets a controller's watchdog notice if the OS silently killed scanning
  /// in the background (confirmed real on some OEMs) — there's no callback
  /// for that, only this poll-able state.
  bool get isScanning => FlutterBluePlus.isScanningNow;

  final Set<String> _loggedDetections = {};

  Future<void> startScanning(
    void Function(String victimDeviceId, BluetoothDevice device, int rssi)
    onVictimDetected,
  ) async {
    try {
      final targetService = Guid(suarServiceUuid);
      await _scanSub?.cancel();
      _loggedDetections.clear();
      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          // Guid.toString() returns its SHORTENED form (e.g. "f00d" for our
          // Bluetooth-base-pattern UUID), not the full 128-bit string — a
          // plain string compare against the full UUID constant never
          // matched. Guid's `==` always compares the normalized 128-bit form.
          final matchesService = r.advertisementData.serviceUuids.contains(
            targetService,
          );
          if (matchesService) {
            final victimDeviceId =
                _decodeVictimDeviceId(r.advertisementData.manufacturerData) ??
                r.device.remoteId.toString();
            // Only log the first sighting — with continuousUpdates on below,
            // this callback now fires repeatedly for the same victim (which
            // is the point: it lets a failed GATT ACK attempt get retried
            // next time the beacon is re-seen), and logging every single one
            // would spam the activity feed.
            if (_loggedDetections.add(victimDeviceId)) {
              _emit('Victim beacon detected: $victimDeviceId rssi=${r.rssi}');
            }
            onVictimDetected(victimDeviceId, r.device, r.rssi);
          }
        }
      });
      await FlutterBluePlus.startScan(
        withServices: [Guid(suarServiceUuid)],
        // continuousUpdates: without this, a device already in the results
        // list is never reported again, so a single failed GATT ACK attempt
        // had no way to be retried short of restarting the whole scan.
        continuousUpdates: true,
        continuousDivisor: 3,
        removeIfGone: const Duration(seconds: 30),
        // Default is lowLatency — meaningfully more battery for scan
        // intervals tighter than this app's BLE ack/relay cadence actually
        // needs (already governed by the cooldowns in
        // VictimController/HelperController, not by how fast the scan
        // itself polls). Matches the same battery-vs-crispness dial-back
        // applied to the advertise side in BlePeripheralHelper.kt.
        androidScanMode: AndroidScanMode.balanced,
      );
      _emit('BLE scanning started');
    } catch (e) {
      _emit('BLE scan failed: $e');
    }
  }

  /// Decodes the deviceId BlePeripheralHelper.kt packs into manufacturer
  /// data, stripping the zero padding used to reach a fixed 20-byte length.
  String? _decodeVictimDeviceId(Map<int, List<int>> manufacturerData) {
    final bytes = manufacturerData[bleManufacturerId];
    if (bytes == null) return null;
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final trimmed = decoded.replaceAll('\u0000', '');
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> stopScanning() async {
    try {
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();
      _scanSub = null;
      _loggedDetections.clear();
      _emit('BLE scanning stopped');
    } catch (e) {
      _emit('Stop scan failed: $e');
    }
  }

  /// Returns success, whether the peer flagged itself as needing the Helper
  /// to pull the bundle instead of pushing it, the peer's role
  /// (bleRoleVictim/bleRoleHelper), and the peer's app deviceId (the UUID
  /// string) — all read from the status characteristic during this same
  /// connection, which costs nothing extra since it's already open for the ack
  /// write. The role tells the caller whether this was actually a distressed
  /// Victim (do the normal handoff) or another Helper (do a DTN relay handshake
  /// instead) — both advertise the same service UUID, so there's no way to tell
  /// them apart before connecting. The peerDeviceId is what lets two Helpers run
  /// a deterministic Wi-Fi Direct group-owner election (see HelperController.
  /// _attemptHelperRelay); it's null only if the read failed or the peer is an
  /// older build that doesn't serve it.
  ///
  /// Also returns whether the peer is joined to a Wi-Fi AP (peerAssociated,
  /// upgrades the election to be association-aware) and whether THIS device
  /// decided it must host the Wi-Fi Direct group for a free Victim it can't
  /// otherwise reach (helperWillHost — written as a 5th ack byte so that Victim
  /// yields its group and pushes here). [myAssociated] is this device's own
  /// AP-join state, supplied by the caller, which feeds that decision.
  Future<
    ({
      bool success,
      bool needsPull,
      int role,
      String? peerDeviceId,
      bool peerAssociated,
      bool helperWillHost,
    })
  >
  sendRssiAck(
    BluetoothDevice device,
    int rssi, {
    bool myAssociated = false,
  }) async {
    try {
      _emit('Connecting to ${device.remoteId} for GATT ACK…');
      // mtu:null skips the automatic MTU negotiation flutter_blue_plus does by
      // default on connect — an extra round-trip we don't need for a 4-byte write.
      await device.connect(timeout: const Duration(seconds: 6), mtu: null);
      // Several Android OEM BLE stacks (Samsung/Oppo included) need the
      // connection to "settle" before service discovery is reliable —
      // calling discoverServices() immediately after connect() resolves is a
      // well-documented source of incomplete/cached service tables on these
      // stacks. A short delay here is cheap insurance.
      await Future.delayed(const Duration(milliseconds: 600));
      // Android also caches each remote's GATT table by MAC address across
      // app runs/installs, independent of the above. Force a fresh read.
      await device.clearGattCache();
      _emit('Connected to ${device.remoteId}, discovering services…');
      var services = await device.discoverServices();
      _emit('Discovered ${services.length} service(s) on ${device.remoteId}');
      // Confirmed on real hardware: even after the settle delay + cache
      // clear above, discoverServices() can occasionally return a truncated
      // table missing our own service (e.g. 3 services instead of the usual
      // 4) — a one-off OEM stack glitch, not a real absence, since the same
      // peer answers fine on the very next contact. One more attempt, after
      // a longer settle, recovers it instead of failing the whole ACK.
      if (!services.any((s) => s.uuid == Guid(suarServiceUuid))) {
        _emit('SUAR service missing from discovery — retrying once…');
        await Future.delayed(const Duration(milliseconds: 800));
        services = await device.discoverServices();
        _emit(
          'Discovered ${services.length} service(s) on ${device.remoteId} (retry)',
        );
      }
      final service = services.firstWhere(
        (s) => s.uuid == Guid(suarServiceUuid),
      );
      var needsPull = false;
      var role = bleRoleVictim;
      String? peerDeviceId;
      var peerAssociated = false;
      try {
        final statusChar = service.characteristics.firstWhere(
          (c) => c.uuid == Guid(suarStatusCharacteristicUuid),
        );
        // Bytes are [0]=needsPull, [1]=role, [2..]=peer's app deviceId (UTF-8);
        // flutter_blue_plus reassembles the full value across READ_BLOBs, so the
        // UUID (longer than the default ATT MTU) arrives intact. See
        // BlePeripheralHelper.onCharacteristicReadRequest.
        final statusBytes = await statusChar.read();
        needsPull = statusBytes.isNotEmpty && statusBytes[0] != 0;
        if (statusBytes.length > 1) role = statusBytes[1];
        if (statusBytes.length > 2) peerAssociated = statusBytes[2] != 0;
        if (statusBytes.length > 3) {
          final decoded = utf8
              .decode(statusBytes.sublist(3), allowMalformed: true)
              .replaceAll(' ', '');
          if (decoded.isNotEmpty) peerDeviceId = decoded;
        }
      } catch (e) {
        // Status characteristic missing/unreadable — treat as "normal
        // Victim push", the existing behaviour, rather than failing the
        // whole ack.
        _emit('Status read skipped: $e');
      }

      // The one case where this device must host instead of pull: it is a
      // Helper joined to a Wi-Fi AP and the peer is a free Victim waiting to be
      // pulled. On a single-radio chipset this device cannot follow that free
      // Victim's group across a channel mismatch, so it tells the Victim (5th
      // ack byte) to yield its group and push here, and becomes the host.
      final helperWillHost =
          needsPull && role == bleRoleVictim && myAssociated && !peerAssociated;
      final characteristic = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(suarGattAckCharacteristicUuid),
      );
      final bytes =
          (ByteData(5)
                ..setInt32(0, rssi, Endian.little)
                ..setUint8(4, helperWillHost ? 1 : 0))
              .buffer
              .asUint8List();
      await characteristic.write(bytes);
      _emit(
        'GATT ACK written to ${device.remoteId} rssi=$rssi host=$helperWillHost',
      );

      await device.disconnect();
      return (
        success: true,
        needsPull: needsPull,
        role: role,
        peerDeviceId: peerDeviceId,
        peerAssociated: peerAssociated,
        helperWillHost: helperWillHost,
      );
    } catch (e) {
      _emit('GATT write failed: $e');
      try {
        await device.disconnect();
      } catch (_) {
        // already disconnected — fine, we're giving up on this attempt anyway.
      }
      return (
        success: false,
        needsPull: false,
        role: bleRoleVictim,
        peerDeviceId: null,
        peerAssociated: false,
        helperWillHost: false,
      );
    }
  }

  void dispose() {
    _scanSub?.cancel();
    _peripheralEventSub?.cancel();
    _statusController.close();
    _helperAckController.close();
  }
}
