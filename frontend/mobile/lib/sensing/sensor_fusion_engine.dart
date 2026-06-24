import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/sensor_reading_model.dart';
import 'device_sensor_probe.dart';
import 'triage_calculator.dart';
import 'triage_config.dart';

/// Collects the live sensor signals that feed triage and folds them into a
/// rolling state the [TriageCalculator] can score. Owns all sensor
/// subscriptions for the four triage sensors (+ gyroscope fused into motion,
/// + light/proximity as weak modifiers); the calculator stays a pure function
/// fed by [currentInputs].
///
/// Subscriptions exist only between [start] and [stop] — Victim Mode keeps
/// radio duty low, so sensing is session-scoped, not always-on.
class SensorFusionEngine {
  SensorFusionEngine({DeviceSensorProbe? probe})
      : _probe = probe ?? DeviceSensorProbe();

  final DeviceSensorProbe _probe;
  final Battery _battery = Battery();

  // --- Tunables (calibration knobs) ---------------------------------------
  static const Duration _accelWindow = Duration(seconds: 5);
  static const Duration _pollInterval = Duration(seconds: 10);
  static const double _motionScale = 3.0; // m/s² stddev ⇒ full motionLevel
  static const double _gyroScale = 3.0; // rad/s ⇒ full motion
  static const double _impactHighG = 20.0; // |a| spike ⇒ impact
  static const double _freeFallG = 3.0; // |a| dip ⇒ free-fall
  static const double _proximityNearCm = 5.0;
  // A real fall is a free-fall dip THEN an impact spike — requiring the dip
  // first rejects the firm "set the phone down on a desk" spike (no free-fall),
  // the main false positive.
  static const Duration _fallLinkWindow = Duration(milliseconds: 1500);
  // |a − gravity| above this counts as PURPOSEFUL movement (getting up, walking
  // — not feeble twitching) and is what cancels a suspected faint. Set high so
  // slow/weak movement after a fall still reads as possibly fainted.
  static const double _moveDeltaG = 4.0;
  // Cap how long one old impact can keep asserting a faint, so a fall hours ago
  // doesn't pin the score forever.
  static const Duration _faintMaxWindow = Duration(minutes: 30);

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<BarometerEvent>? _baroSub;
  StreamSubscription<NoiseReading>? _micSub;
  Timer? _pollTimer;

  final List<_Sample> _accelMags = [];
  double _gyroMag = 0.0;
  double? _baroBaseline;
  double? _baroCurrent;
  double? _micDb;
  double? _lux;
  bool? _proxNear;
  double? _batteryLevel;
  bool _charging = false;
  double? _drainPerMin;
  double? _lastBatteryLevel;
  DateTime? _lastBatteryAt;

  // Fall/faint temporal state.
  DateTime? _freeFallAt;
  DateTime? _lastImpactAt;
  DateTime? _lastMotionAt;

  bool _running = false;

  /// Starts all sensor subscriptions. [withMic] should reflect whether the
  /// RECORD_AUDIO permission is granted — mic is skipped (and its triage term
  /// renormalises away) when false or if the stream errors.
  Future<void> start({bool withMic = true}) async {
    if (_running) return;
    _running = true;

    // Pick up any saved triage tuning (editor changes apply on next recompute
    // because evaluate() reads TriageConfig.active each time).
    await TriageConfig.load();

    _accelSub = accelerometerEventStream().listen((e) {
      final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      final now = DateTime.now();
      _accelMags.add(_Sample(mag, now));
      _accelMags.removeWhere((s) => now.difference(s.time) > _accelWindow);
      // Fall = free-fall dip followed shortly by an impact spike.
      if (mag < _freeFallG) _freeFallAt = now;
      if (mag > _impactHighG &&
          _freeFallAt != null &&
          now.difference(_freeFallAt!) < _fallLinkWindow) {
        _lastImpactAt = now;
      }
      // Genuine movement (resets the "still since the fall" clock).
      if ((mag - 9.81).abs() > _moveDeltaG) _lastMotionAt = now;
    }, onError: (_) {});

    _gyroSub = gyroscopeEventStream().listen((e) {
      _gyroMag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    }, onError: (_) {});

    _baroSub = barometerEventStream().listen((e) {
      _baroCurrent = e.pressure;
      _baroBaseline ??= e.pressure; // first reading is the session baseline
    }, onError: (_) {});

    if (withMic) {
      try {
        _micSub = NoiseMeter().noise.listen(
          (r) => _micDb = r.meanDecibel,
          onError: (_) => _micDb = null,
          cancelOnError: true,
        );
      } catch (_) {
        _micDb = null;
      }
    }

    await _poll(); // prime battery/light/proximity immediately
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    await _accelSub?.cancel();
    await _gyroSub?.cancel();
    await _baroSub?.cancel();
    await _micSub?.cancel();
    _accelSub = _gyroSub = null;
    _baroSub = null;
    _micSub = null;
    _accelMags.clear();
    _baroBaseline = _baroCurrent = null;
    _micDb = _lux = _proxNear = null;
    _freeFallAt = _lastImpactAt = _lastMotionAt = null;
  }

  Future<void> _poll() async {
    try {
      final level = (await _battery.batteryLevel).toDouble();
      final state = await _battery.batteryState;
      _charging = state == BatteryState.charging || state == BatteryState.full;
      final now = DateTime.now();
      if (_lastBatteryLevel != null && _lastBatteryAt != null) {
        final dropped = _lastBatteryLevel! - level; // positive = draining
        final mins = now.difference(_lastBatteryAt!).inMilliseconds / 60000.0;
        if (mins > 0) _drainPerMin = math.max(0.0, dropped / mins);
      }
      _lastBatteryLevel = level;
      _lastBatteryAt = now;
      _batteryLevel = level;
    } catch (_) {/* battery unavailable — term renormalises out */}

    final lux = await _probe.readOnce('light');
    if (lux != null) _lux = lux;
    final prox = await _probe.readOnce('proximity');
    if (prox != null) _proxNear = prox < _proximityNearCm;
  }

  /// Snapshot of the current fused state for the [TriageCalculator]. Reads
  /// fall-latch / faint timing against the live [TriageConfig.active] windows.
  TriageInputs get currentInputs {
    final cfg = TriageConfig.active;
    final now = DateTime.now();

    double? motionLevel;
    if (_accelMags.isNotEmpty) {
      final mags = _accelMags.map((s) => s.mag).toList();
      final accelMotion = (_stddev(mags) / _motionScale).clamp(0.0, 1.0);
      final gyroMotion = (_gyroMag / _gyroScale).clamp(0.0, 1.0);
      motionLevel = math.max(accelMotion, gyroMotion);
    }

    // A detected impact stays latched for a window so a momentary spike keeps
    // counting instead of vanishing on the next cycle.
    final impactLatched = _lastImpactAt != null &&
        now.difference(_lastImpactAt!).inMilliseconds <
            (cfg.fallLatchSeconds * 1000).round();
    // Faint = impact, then no movement since, for an extended period.
    final immobileSinceImpact = _lastImpactAt != null &&
        (_lastMotionAt == null || _lastMotionAt!.isBefore(_lastImpactAt!));
    final fainted = _lastImpactAt != null &&
        immobileSinceImpact &&
        now.difference(_lastImpactAt!).inSeconds >= cfg.faintImmobileSeconds &&
        now.difference(_lastImpactAt!) < _faintMaxWindow;

    final pressureDeviation = (_baroBaseline != null && _baroCurrent != null)
        ? (_baroCurrent! - _baroBaseline!).abs()
        : null;

    return TriageInputs(
      motionLevel: motionLevel,
      impactDetected: impactLatched,
      faintedSuspected: fainted,
      pressureDeviation: pressureDeviation,
      micDecibel: _micDb,
      lux: _lux,
      proximityNear: _proxNear,
      batteryLevel: _batteryLevel,
      batteryDrainPerMin: _drainPerMin,
      batteryCharging: _charging,
    );
  }

  /// Raw physical readings keyed by triage sensor, for pairing with the
  /// normalised values into SensorReading rows. Only includes sensors that
  /// currently have a reading.
  Map<String, double> get rawTriageValues {
    final out = <String, double>{};
    if (_accelMags.isNotEmpty) {
      out[TriageSensor.accelerometer] = _accelMags.last.mag;
    }
    if (_baroCurrent != null) out[TriageSensor.barometer] = _baroCurrent!;
    if (_micDb != null) out[TriageSensor.microphone] = _micDb!;
    if (_batteryLevel != null) out[TriageSensor.battery] = _batteryLevel!;
    return out;
  }

  /// Evaluate triage now and build the matching SensorReading rows for [bundleId].
  ({TriageResult result, List<SensorReadingModel> readings}) evaluate(
      String bundleId) {
    final result = TriageCalculator.evaluate(currentInputs);
    final raws = rawTriageValues;
    final readings = <SensorReadingModel>[];
    result.normalised.forEach((sensorType, normalised) {
      readings.add(SensorReadingModel(
        bundleId: bundleId,
        sensorType: sensorType,
        rawValue: raws[sensorType] ?? 0.0,
        normalisedValue: normalised,
      ));
    });
    return (result: result, readings: readings);
  }

  static double _stddev(List<double> xs) {
    if (xs.length < 2) return 0.0;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final variance =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return math.sqrt(variance);
  }

  void dispose() {
    if (_running) unawaited(stop());
  }
}

class _Sample {
  _Sample(this.mag, this.time);
  final double mag;
  final DateTime time;
}
