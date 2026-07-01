import 'dart:math' as math;

import '../models/sensor_reading_model.dart';
import 'triage_config.dart';

/// Scalar sensor features the [TriageCalculator] consumes. The
/// [SensorFusionEngine] does the time-windowing (peaks, variance, drain rate,
/// fall latching) and hands these plain numbers over, keeping the calculator a
/// pure, unit-testable function. A `null` field means that sensor is absent or
/// has no reading yet — it contributes no points.
class TriageInputs {
  const TriageInputs({
    this.motionLevel,
    this.impactDetected = false,
    this.faintedSuspected = false,
    this.pressureDeviation,
    this.micDecibel,
    this.lux,
    this.proximityNear,
    this.batteryLevel,
    this.batteryDrainPerMin,
    this.batteryCharging = false,
  });

  final double? motionLevel;
  final bool impactDetected;
  final bool faintedSuspected;
  final double? pressureDeviation;
  final double? micDecibel;
  final double? lux;
  final bool? proximityNear;
  final double? batteryLevel;
  final double? batteryDrainPerMin;
  final bool batteryCharging;
}

/// One named contribution to the score, for the live breakdown. [detail] is the
/// raw reading that produced it (e.g. "52 dB", "18%"), shown next to the label.
typedef ScorePart = ({String label, double points, String detail});

/// Canonical flag keys carried on the bundle so a Helper can surface them.
class TriageFlag {
  TriageFlag._();
  static const String fall = 'fall';
  static const String faint = 'faint';
  static const String lowBattery = 'lowBattery';
  static const String criticalBattery = 'criticalBattery';

  static const Map<String, String> labels = {
    fall: 'Recent fall',
    faint: 'Possibly fainted',
    lowBattery: 'Low battery',
    criticalBattery: 'Critical battery',
  };
}

class TriageResult {
  const TriageResult({
    required this.score,
    required this.tier,
    required this.normalised,
    required this.breakdown,
    required this.flags,
    this.note,
  });

  /// Composite risk in **points** (additive; clamped to the configured cap).
  final double score;

  /// One of Critical / High / Moderate / Low.
  final String tier;

  /// Per-triage-sensor normalised risk (0..1, keys ⊂ [TriageSensor.all]).
  final Map<String, double> normalised;

  /// Per-component points, in scoring order — drives the live breakdown.
  final List<ScorePart> breakdown;

  /// Active safety flags ([TriageFlag] keys) for the Helper UI.
  final List<String> flags;

  final String? note;
}

/// Additive points triage scoring, driven by a [TriageConfig]. Normalisers are
/// calibrated so a NORMAL reading scores ~0 — only abnormal readings add
/// points, so a calm phone stays near zero. Pure given its config.
class TriageCalculator {
  TriageCalculator._();

  static double _clamp01(double v) => v.clamp(0.0, 1.0);

  /// Movement alone is not distress; motion only scores once an impact is
  /// detected: impact + motionless ⇒ ~1.0; impact + still moving ⇒ ~0.5.
  static double motionRisk(double motionLevel, bool impact) {
    if (!impact) return 0.0;
    final immobility = _clamp01(1.0 - motionLevel);
    return _clamp01(0.5 + 0.5 * immobility);
  }

  /// 0 above the comfort level, ramping as charge falls below it. Charging
  /// suppresses it.
  static double batteryRisk(
      double level, double? drainPerMin, bool charging, TriageConfig c) {
    final comfort = c.batteryComfortLevel <= 0 ? 1.0 : c.batteryComfortLevel;
    final lowness = _clamp01((comfort - level) / comfort);
    final drain = drainPerMin == null
        ? 0.0
        : _clamp01(drainPerMin / c.batteryFastDrainPerMin);
    var risk = 0.7 * lowness + 0.3 * drain;
    if (charging) risk *= 0.4;
    return _clamp01(risk);
  }

  static double micRisk(double db, TriageConfig c) {
    final span = c.micMaxDb - c.micMinDb;
    if (span <= 0) return 0.0;
    return _clamp01((db - c.micMinDb) / span);
  }

  /// Both extremes are risky: darkness (trapped/buried) and very bright
  /// (exposed to direct sun) — whichever is stronger.
  static double lightRisk(double lux, TriageConfig c) {
    final dark = c.darkBelowLux > 0
        ? _clamp01((c.darkBelowLux - lux) / c.darkBelowLux)
        : 0.0;
    final bright = c.brightAboveLux > 0
        ? _clamp01((lux - c.brightAboveLux) / c.brightAboveLux)
        : 0.0;
    return math.max(dark, bright);
  }

  static String tierForScore(double score, TriageConfig c) {
    if (score >= c.criticalThreshold) return 'Critical';
    if (score >= c.highThreshold) return 'High';
    if (score >= c.moderateThreshold) return 'Moderate';
    return 'Low';
  }

  static TriageResult evaluate(TriageInputs i, [TriageConfig? config]) {
    final c = config ?? TriageConfig.active;
    final normalised = <String, double>{};
    final breakdown = <ScorePart>[];
    final flags = <String>[];
    var points = 0.0;

    void add(String label, double pts, String detail) {
      points += pts;
      breakdown.add((label: label, points: pts, detail: detail));
    }

    if (i.motionLevel != null) {
      final r = motionRisk(i.motionLevel!, i.impactDetected);
      add('Motion', c.wMotion * r,
          '${(i.motionLevel! * 100).round()}% move${i.impactDetected ? ', impact' : ''}');
      normalised[TriageSensor.accelerometer] = r;
    }
    if (i.batteryLevel != null) {
      final r = batteryRisk(
          i.batteryLevel!, i.batteryDrainPerMin, i.batteryCharging, c);
      add('Battery', c.wBattery * r,
          '${i.batteryLevel!.round()}%${i.batteryCharging ? ', charging' : ''}');
      normalised[TriageSensor.battery] = r;
    }
    if (i.micDecibel != null) {
      final r = micRisk(i.micDecibel!, c);
      add('Microphone', c.wMic * r, '${i.micDecibel!.round()} dB');
      normalised[TriageSensor.microphone] = r;
    }
    if (i.pressureDeviation != null) {
      final r = _clamp01(i.pressureDeviation! / c.pressureMaxDeviationHpa);
      add('Barometer', c.wBarometer * r,
          '${i.pressureDeviation!.toStringAsFixed(1)} hPa Δ');
      normalised[TriageSensor.barometer] = r;
    }
    if (i.lux != null) {
      add('Light', c.wLight * lightRisk(i.lux!, c), '${i.lux!.round()} lx');
    }
    if (i.proximityNear != null) {
      add('Proximity', c.wProximity * (i.proximityNear! ? 1.0 : 0.0),
          i.proximityNear! ? 'covered' : 'clear');
    }

    // Safety rules — additive boosts. A rule's condition can be the real sensor
    // state OR a debug "force" switch (for end-to-end testing). Forced-only
    // boosts are tagged "simulated" in the breakdown.
    final notCharging = !i.batteryCharging;
    final batteryReal = i.batteryLevel != null && notCharging;
    final realCrit = batteryReal && i.batteryLevel! <= c.criticalBatteryThreshold;
    final realLow = batteryReal && i.batteryLevel! <= c.lowBatteryThreshold;

    if (c.fallEnabled && (i.impactDetected || c.forceFall)) {
      add('Fall', c.fallBoost, i.impactDetected ? 'recent fall' : 'simulated');
      flags.add(TriageFlag.fall);
    }
    if (c.faintEnabled && (i.faintedSuspected || c.forceFaint)) {
      add('Faint', c.faintBoost,
          i.faintedSuspected ? 'immobile after fall' : 'simulated');
      flags.add(TriageFlag.faint);
    }
    // Battery rules are mutually exclusive — critical supersedes low so the two
    // don't stack (no 30 + 15 double-count). Force switches respect the same
    // exclusion (forced-critical wins over forced-low).
    if (c.criticalBatteryEnabled && (realCrit || c.forceCriticalBattery)) {
      add('Critical battery', c.criticalBatteryBoost,
          realCrit ? '≤${c.criticalBatteryThreshold.round()}%' : 'simulated');
      flags.add(TriageFlag.criticalBattery);
    } else if (c.lowBatteryEnabled && (realLow || c.forceLowBattery)) {
      add('Low battery', c.lowBatteryBoost,
          realLow ? '≤${c.lowBatteryThreshold.round()}%' : 'simulated');
      flags.add(TriageFlag.lowBattery);
    }

    final raw = points < 0 ? 0.0 : points;
    final score = c.scoreCap > 0 ? raw.clamp(0.0, c.scoreCap).toDouble() : raw;
    // "Running blind" only when truly nothing contributed — a forced boost
    // still produces a real (testable) result.
    if (breakdown.isEmpty) {
      return const TriageResult(
        score: 0.0,
        tier: 'Low',
        normalised: {},
        breakdown: [],
        flags: [],
        note: 'No sensors available. Triage running blind.',
      );
    }
    return TriageResult(
      score: score,
      tier: tierForScore(score, c),
      normalised: normalised,
      breakdown: breakdown,
      flags: flags,
    );
  }
}
