import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/sensor_reading_model.dart';
import 'device_sensor_probe.dart';
import 'mic_guard.dart';
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
  SensorFusionEngine({
    DeviceSensorProbe? probe,
    this.microphoneOwner = MicrophoneSessionOwner.victimTriage,
  }) : _probe = probe ?? DeviceSensorProbe();

  final DeviceSensorProbe _probe;
  final MicrophoneSessionOwner microphoneOwner;
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
  // A faint does not require perfectly zero movement: during the post-fall
  // observation window, low movement must cover this fraction of the window.
  // With the default 20-second window that is 15 seconds.
  static const double _faintLowMovementFraction = 0.75;
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
  final List<_MotionSample> _postFallMotion = [];

  bool _running = false;
  int _session = 0;
  int? _pollInFlightSession;

  bool get microphoneActive => _micSub != null;

  /// Starts all sensor subscriptions. [withMic] should reflect whether the
  /// RECORD_AUDIO permission is granted — mic is skipped (and its triage term
  /// is omitted) when false or if the stream errors.
  Future<void> start({bool withMic = true}) async {
    if (_running) return;
    _running = true;
    final session = ++_session;

    try {
      // Pick up any saved triage tuning (editor changes apply on next
      // recompute because evaluate() reads TriageConfig.active each time).
      await TriageConfig.load();
      if (!_isCurrentSession(session)) return;

      _accelSub = accelerometerEventStream().listen((e) {
        if (!_isCurrentSession(session)) return;
        final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
        final now = DateTime.now();
        _accelMags.add(_Sample(mag, now));
        _accelMags.removeWhere((s) => now.difference(s.time) > _accelWindow);
        // Fall = free-fall dip followed shortly by an impact spike.
        if (mag < _freeFallG) _freeFallAt = now;
        final fallDetected = mag > _impactHighG &&
            _freeFallAt != null &&
            now.difference(_freeFallAt!) < _fallLinkWindow;
        if (fallDetected) {
          _lastImpactAt = now;
          _lastMotionAt = null;
          // Do not count the impact spike itself as recovery movement. Start
          // the faint observation as low movement and classify later samples.
          _postFallMotion
            ..clear()
            ..add(_MotionSample(now, purposeful: false));
        }
        final purposefulMovement = (mag - 9.81).abs() > _moveDeltaG;
        // Only samples inside the configurable observation window affect the
        // 75%-low-movement decision. Later purposeful movement clears a faint.
        if (!fallDetected && _lastImpactAt != null) {
          final observationWindow = _faintObservationWindow(TriageConfig.active);
          if (now.difference(_lastImpactAt!) <= observationWindow) {
            _postFallMotion.add(
              _MotionSample(now, purposeful: purposefulMovement),
            );
          }
        }
        if (purposefulMovement && !fallDetected) _lastMotionAt = now;
      }, onError: (_) {});

      _gyroSub = gyroscopeEventStream().listen((e) {
        if (!_isCurrentSession(session)) return;
        _gyroMag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      }, onError: (_) {});

      _baroSub = barometerEventStream().listen((e) {
        if (!_isCurrentSession(session)) return;
        _baroCurrent = e.pressure;
        _baroBaseline ??= e.pressure; // first reading is the session baseline
      }, onError: (_) {});

      if (withMic) {
        try {
          // guardedNoiseStream (not NoiseMeter().noise directly): spaces mic
          // sessions out so a quick Victim-mode exit → re-entry can't overlap
          // audio_streamer's shared native recorder — see mic_guard.dart.
          _micSub = guardedNoiseStream(owner: microphoneOwner).listen(
            (r) {
              if (_isCurrentSession(session)) _micDb = r.meanDecibel;
            },
            onError: (_) {
              if (_isCurrentSession(session)) _micDb = null;
            },
            cancelOnError: true,
          );
        } catch (_) {
          _micDb = null;
        }
      }

      await _poll(session); // prime battery/light/proximity immediately
      if (!_isCurrentSession(session)) return;
      _pollTimer = Timer.periodic(
        _pollInterval,
        (_) => unawaited(_poll(session)),
      );
    } catch (_) {
      if (_isCurrentSession(session)) await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _session++;

    final pollTimer = _pollTimer;
    final accelSub = _accelSub;
    final gyroSub = _gyroSub;
    final baroSub = _baroSub;
    final micSub = _micSub;
    _pollTimer = null;
    _accelSub = null;
    _gyroSub = null;
    _baroSub = null;
    _micSub = null;

    pollTimer?.cancel();
    _accelMags.clear();
    _baroBaseline = _baroCurrent = null;
    _micDb = _lux = _proxNear = null;
    _freeFallAt = _lastImpactAt = _lastMotionAt = null;
    _postFallMotion.clear();
    // Session-scoped like everything above: a stale gyro magnitude fed the
    // next session's motionLevel until the first new event, and stale battery
    // bookkeeping computed a drain rate across the stopped gap.
    _gyroMag = 0.0;
    _batteryLevel = _drainPerMin = _lastBatteryLevel = null;
    _lastBatteryAt = null;
    _charging = false;

    await Future.wait([
      _cancelSubscription(accelSub),
      _cancelSubscription(gyroSub),
      _cancelSubscription(baroSub),
      _cancelSubscription(micSub),
    ]);
  }

  bool _isCurrentSession(int session) => _running && _session == session;

  Future<void> _cancelSubscription(StreamSubscription<dynamic>? sub) async {
    try {
      await sub?.cancel();
    } catch (_) {
      // Best-effort cleanup: one plugin cancellation must not leak the rest.
    }
  }

  Future<void> _poll(int session) async {
    if (!_isCurrentSession(session) || _pollInFlightSession == session) return;
    _pollInFlightSession = session;
    try {
      try {
        final level = (await _battery.batteryLevel).toDouble();
        final state = await _battery.batteryState;
        if (!_isCurrentSession(session)) return;
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
      } catch (_) {
        // Battery unavailable: omit its triage term.
      }

      try {
        final lux = await _probe.readOnce('light');
        if (_isCurrentSession(session) && lux != null) _lux = lux;
      } catch (_) {
        // Optional sensor unavailable.
      }
      try {
        final prox = await _probe.readOnce('proximity');
        if (_isCurrentSession(session) && prox != null) {
          _proxNear = prox < _proximityNearCm;
        }
      } catch (_) {
        // Optional sensor unavailable.
      }
    } finally {
      if (_pollInFlightSession == session) _pollInFlightSession = null;
    }
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
    // After a fall, observe for the configured period (20 seconds by default).
    // Faint requires low movement for 75% of that window (15 seconds by
    // default), rather than absolute stillness. Once fainted, a later strong
    // movement clears the flag so recovery is reflected in the next triage run.
    final observationWindow = _faintObservationWindow(cfg);
    final fainted = _lastImpactAt != null &&
        now.difference(_lastImpactAt!) >= observationWindow &&
        now.difference(_lastImpactAt!) < _faintMaxWindow &&
        (_lastMotionAt == null ||
            _lastMotionAt!.isBefore(_lastImpactAt!.add(observationWindow))) &&
        _lowMovementDuration(_lastImpactAt!, observationWindow) >=
            _requiredLowMovement(observationWindow);

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

  static Duration _faintObservationWindow(TriageConfig config) {
    final milliseconds = (config.faintImmobileSeconds * 1000).round();
    return Duration(milliseconds: math.max(1, milliseconds));
  }

  static Duration _requiredLowMovement(Duration observationWindow) => Duration(
        milliseconds:
            (observationWindow.inMilliseconds * _faintLowMovementFraction)
                .round(),
      );

  Duration _lowMovementDuration(DateTime startedAt, Duration observationWindow) {
    if (_postFallMotion.isEmpty) return Duration.zero;

    final endsAt = startedAt.add(observationWindow);
    var lowMilliseconds = 0;
    for (var index = 0; index < _postFallMotion.length; index++) {
      final sample = _postFallMotion[index];
      final intervalStart = sample.time.isBefore(startedAt) ? startedAt : sample.time;
      final nextTime = index + 1 < _postFallMotion.length
          ? _postFallMotion[index + 1].time
          : endsAt;
      final intervalEnd = nextTime.isAfter(endsAt) ? endsAt : nextTime;
      if (!sample.purposeful && intervalEnd.isAfter(intervalStart)) {
        lowMilliseconds += intervalEnd.difference(intervalStart).inMilliseconds;
      }
    }
    return Duration(milliseconds: lowMilliseconds);
  }

  void dispose() {
    if (_running ||
        _pollTimer != null ||
        _accelSub != null ||
        _gyroSub != null ||
        _baroSub != null ||
        _micSub != null) {
      unawaited(stop());
    }
  }
}

class _Sample {
  _Sample(this.mag, this.time);
  final double mag;
  final DateTime time;
}

class _MotionSample {
  const _MotionSample(this.time, {required this.purposeful});

  final DateTime time;
  final bool purposeful;
}
