import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the `suar/sensors` native channel ([SensorProbe.kt]).
/// Covers hardware-availability for all SensorManager sensors plus one-shot
/// reads and continuous streams for the two the app doesn't stream via
/// sensors_plus (proximity, ambient light), and a cross-profile Bluetooth
/// connected-device query. Never throws — a dead channel reports "unavailable"
/// rather than crashing the diagnostic UI.
class DeviceSensorProbe {
  static const MethodChannel _channel = MethodChannel('suar/sensors');
  static const EventChannel _events = EventChannel('suar/sensors_events');
  static Stream<dynamic>? _rawEvents;

  /// sensorKey -> whether the hardware exists. Keys match
  /// [DeviceSensorMeta.nativeKey] (accelerometer, gyroscope, magnetometer,
  /// barometer, proximity, light). Empty map if the channel is unavailable.
  Future<Map<String, bool>> getAvailability() async {
    try {
      final raw = await _channel.invokeMapMethod<String, bool>('getAvailability');
      return raw ?? const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Whether the Wi-Fi radio is on (Wi-Fi Direct needs it). False if unknown.
  Future<bool> isWifiEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isWifiEnabled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Hardware characteristics of [key] (maxRange, resolution, name, vendor),
  /// or empty if absent/unavailable.
  Future<Map<String, dynamic>> getSensorInfo(String key) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getSensorInfo',
        {'key': key},
      );
      return raw ?? const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// One-shot latest reading for [key] (cm for proximity, lux for light), or
  /// null if the sensor is absent or silent within [timeoutMs].
  Future<double?> readOnce(String key, {int timeoutMs = 600}) async {
    try {
      final value = await _channel.invokeMethod<double>(
        'readSensor',
        {'key': key, 'timeoutMs': timeoutMs},
      );
      return value;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// A continuous stream of live values for [key] (proximity/light). Registers
  /// a persistent native listener while subscribed (reliable cover/uncover,
  /// unlike polling [readOnce]) and unregisters it on cancel.
  Stream<double> sensorStream(String key) {
    final raw = _rawEvents ??= _events.receiveBroadcastStream();
    late StreamController<double> ctrl;
    StreamSubscription<dynamic>? sub;
    ctrl = StreamController<double>(
      onListen: () {
        _channel.invokeMethod('startSensorStream', {'key': key});
        sub = raw.listen((event) {
          if (event is Map && event['key'] == key) {
            final v = event['value'];
            if (v is num) ctrl.add(v.toDouble());
          }
        }, onError: (_) {});
      },
      onCancel: () async {
        await sub?.cancel();
        try {
          await _channel.invokeMethod('stopSensorStream', {'key': key});
        } catch (_) {}
      },
    );
    return ctrl.stream;
  }

  /// How many devices the OS currently has connected over Bluetooth (GATT +
  /// classic audio profiles), beyond just this app's BLE connections. 0 if
  /// Bluetooth is off or the query is unavailable.
  Future<int> bluetoothConnectedCount() async {
    try {
      return await _channel.invokeMethod<int>('bluetoothConnectedDevices') ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }
}
