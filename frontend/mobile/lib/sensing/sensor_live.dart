import 'dart:async';
import 'dart:math' as math;

import 'package:noise_meter/noise_meter.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'device_sensor_probe.dart';
import 'sensor_types.dart';

double _mag(double x, double y, double z) => math.sqrt(x * x + y * y + z * z);

/// Standard sea-level pressure (hPa) — matches SensorManager.getAltitude's
/// PRESSURE_STANDARD_ATMOSPHERE. For a precise altitude this should be the
/// local sea-level pressure (a calibration knob); with the standard value the
/// reading is approximate, hence the "~".
const double _seaLevelHpa = 1013.25;

/// Barometric altitude formula (the same one SensorManager.getAltitude uses).
double _altitudeMeters(double pressureHpa) =>
    44330.0 * (1.0 - math.pow(pressureHpa / _seaLevelHpa, 1.0 / 5.255));

const List<String> _compass = [
  'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW',
];

String _cardinal(double deg) => _compass[(((deg + 22.5) % 360) ~/ 45)];

/// Human label for a lux reading (rough, standard daylight references).
String _lightLabel(double lux) {
  if (lux < 10) return 'Dark';
  if (lux < 50) return 'Dim';
  if (lux < 200) return 'Indoor (low)';
  if (lux < 500) return 'Indoor';
  if (lux < 1000) return 'Bright indoor';
  if (lux < 10000) return 'Overcast daylight';
  if (lux < 25000) return 'Daylight';
  return 'Direct sunlight';
}

/// Per-device interpretation of a proximity reading. Cheap sensors are binary
/// (only 0 ↔ maxRange), so cm is meaningless on them — we then show Near/Far
/// only. See [DeviceSensorProbe.getSensorInfo].
class ProximityInfo {
  const ProximityInfo({required this.maxRange, required this.continuous});

  /// Far-state value the sensor reports (cm). Near ⇔ reading < maxRange.
  final double maxRange;

  /// True only if the sensor reports a real distance range, not just two states.
  final bool continuous;

  static const ProximityInfo unknown =
      ProximityInfo(maxRange: 5.0, continuous: false);
}

/// A live, fully-formatted reading for one [DeviceSensor], shown when its row
/// is expanded on the Device Test page. Each sensor formats itself into the
/// most informative form its hardware allows (heading, altitude, brightness
/// label, near/far) rather than a bare number. Connectivity sensors are not
/// numeric — the screen handles those as Enabled/Disabled, so calling this for
/// them throws.
///
/// Holds no resources until listened to; cancelling releases everything
/// (so a collapsed row is simply unsubscribed = paused).
Stream<String> liveSensorLabel(
  DeviceSensor sensor,
  DeviceSensorProbe probe, {
  ProximityInfo proximity = ProximityInfo.unknown,
}) {
  switch (sensor) {
    case DeviceSensor.accelerometer:
      return accelerometerEventStream().map((e) {
        final m = _mag(e.x, e.y, e.z);
        final moving = (m - 9.81).abs() > 0.6;
        return '${m.toStringAsFixed(2)} m/s²  ·  ${moving ? 'moving' : 'still'}';
      });
    case DeviceSensor.gyroscope:
      return gyroscopeEventStream().map((e) {
        final m = _mag(e.x, e.y, e.z);
        return '${m.toStringAsFixed(2)} rad/s  ·  ${m > 0.15 ? 'rotating' : 'still'}';
      });
    case DeviceSensor.barometer:
      return barometerEventStream().map((e) =>
          '${e.pressure.toStringAsFixed(1)} hPa  ·  ~${_altitudeMeters(e.pressure).round()} m');
    case DeviceSensor.magnetometer:
      return _headingStream();
    case DeviceSensor.microphone:
      return NoiseMeter().noise.map((r) => '${r.meanDecibel.toStringAsFixed(1)} dB');
    case DeviceSensor.proximity:
      // Emit only when the near/far state actually FLIPS. Some OEM proximity
      // sensors (e.g. Samsung exposes a continuous "palm" gesture sensor in
      // place of a clean binary one) stream constantly; debouncing to the flip
      // keeps the row stable and meaningful instead of a flickering number.
      bool? lastNear;
      return probe.sensorStream('proximity').where((v) {
        final near = v < proximity.maxRange;
        if (near == lastNear) return false;
        lastNear = near;
        return true;
      }).map((v) => v < proximity.maxRange ? 'Near (covered)' : 'Far (clear)');
    case DeviceSensor.light:
      return probe
          .sensorStream('light')
          .map((lux) => '${lux.round()} lx  ·  ${_lightLabel(lux)}');
    case DeviceSensor.gps:
    case DeviceSensor.bluetooth:
    case DeviceSensor.wifi:
      throw ArgumentError('${sensor.label} is not a numeric sensor');
  }
}

/// Tilt-compensated compass heading by fusing the accelerometer (gravity) and
/// magnetometer, per the official getRotationMatrix → getOrientation method.
/// Emits "NE  47°  ·  45 µT" style labels.
Stream<String> _headingStream() {
  late StreamController<String> controller;
  StreamSubscription<AccelerometerEvent>? aSub;
  StreamSubscription<MagnetometerEvent>? mSub;
  List<double>? gravity;
  List<double>? geomag;

  void compute() {
    final g = gravity, m = geomag;
    if (g == null || m == null) return;
    final r = _rotationMatrix(g, m);
    if (r == null) return;
    // getOrientation: azimuth = atan2(R[1], R[4]).
    var deg = math.atan2(r[1], r[4]) * 180.0 / math.pi;
    deg = (deg + 360.0) % 360.0;
    final fieldUt = _mag(m[0], m[1], m[2]);
    controller.add(
        '${_cardinal(deg)}  ${deg.round()}°  ·  ${fieldUt.round()} µT');
  }

  controller = StreamController<String>(
    onListen: () {
      aSub = accelerometerEventStream().listen((e) {
        gravity = [e.x, e.y, e.z];
        compute();
      }, onError: (_) {});
      mSub = magnetometerEventStream().listen((e) {
        geomag = [e.x, e.y, e.z];
        compute();
      }, onError: (_) {});
    },
    onCancel: () async {
      await aSub?.cancel();
      await mSub?.cancel();
    },
  );
  return controller.stream;
}

/// Port of SensorManager.getRotationMatrix (R only). Returns the 3×3 matrix as
/// a flat 9-element list, or null if the device is in free-fall / near a strong
/// magnet (degenerate geometry).
List<double>? _rotationMatrix(List<double> gravity, List<double> geomag) {
  final ax = gravity[0], ay = gravity[1], az = gravity[2];
  final ex = geomag[0], ey = geomag[1], ez = geomag[2];
  var hx = ey * az - ez * ay;
  var hy = ez * ax - ex * az;
  var hz = ex * ay - ey * ax;
  final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
  if (normH < 0.1) return null;
  final invH = 1.0 / normH;
  hx *= invH;
  hy *= invH;
  hz *= invH;
  final invA = 1.0 / math.sqrt(ax * ax + ay * ay + az * az);
  final nax = ax * invA, nay = ay * invA, naz = az * invA;
  final mx = nay * hz - naz * hy;
  final my = naz * hx - nax * hz;
  final mz = nax * hy - nay * hx;
  return [hx, hy, hz, mx, my, mz, nax, nay, naz];
}
