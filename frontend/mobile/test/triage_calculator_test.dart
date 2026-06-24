import 'package:flutter_test/flutter_test.dart';
import 'package:suar_mobile/models/sensor_reading_model.dart';
import 'package:suar_mobile/sensing/triage_calculator.dart';
import 'package:suar_mobile/sensing/triage_config.dart';

void main() {
  final cfg = TriageConfig.defaults();

  group('TriageCalculator (additive points, recalibrated)', () {
    test('no sensors available → Low with a blind-triage note', () {
      final r = TriageCalculator.evaluate(const TriageInputs(), cfg);
      expect(r.tier, 'Low');
      expect(r.score, 0.0);
      expect(r.note, isNotNull);
      expect(r.normalised, isEmpty);
    });

    test('a calm phone with every sensor present scores ~0 (Low)', () {
      // The desk-phone bug: normal readings must not accrue points.
      final r = TriageCalculator.evaluate(
        const TriageInputs(
          motionLevel: 0.05, // tiny vibration, no impact
          impactDetected: false,
          pressureDeviation: 0.2,
          micDecibel: 45, // quiet room (below the 55 dB floor)
          lux: 300, // lit room
          proximityNear: false,
          batteryLevel: 80, // healthy (above comfort)
          batteryDrainPerMin: 0.2,
        ),
        cfg,
      );
      expect(r.tier, 'Low');
      expect(r.score, lessThan(5)); // essentially zero
    });

    test('movement without an impact adds no motion points', () {
      final still =
          TriageCalculator.evaluate(const TriageInputs(motionLevel: 0.0), cfg);
      final moving =
          TriageCalculator.evaluate(const TriageInputs(motionLevel: 0.9), cfg);
      expect(still.score, 0.0);
      expect(moving.score, 0.0);
    });

    test('fall while still moving → Moderate-ish, fall boost included', () {
      const inputs = TriageInputs(
          motionLevel: 0.9, impactDetected: true, batteryLevel: 100);
      final r = TriageCalculator.evaluate(inputs, cfg);
      expect(['Moderate', 'High'], contains(r.tier));
      expect(r.breakdown.map((p) => p.label), contains('Fall'));
    });

    test('fall + sustained immobility (faint) → Critical', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(
          motionLevel: 0.0,
          impactDetected: true,
          faintedSuspected: true,
          batteryLevel: 100,
        ),
        cfg,
      );
      expect(r.tier, 'Critical');
      expect(r.breakdown.map((p) => p.label), contains('Faint'));
      expect(r.flags, contains('faint'));
    });

    test('battery rules are mutually exclusive (critical supersedes low)', () {
      final r = TriageCalculator.evaluate(
          const TriageInputs(batteryLevel: 10), cfg); // ≤15 and ≤30
      final labels = r.breakdown.map((p) => p.label);
      expect(labels, contains('Critical battery'));
      expect(labels, isNot(contains('Low battery')));
      expect(r.flags, contains('criticalBattery'));
      expect(r.flags, isNot(contains('lowBattery')));
    });

    test('extreme brightness (direct sun) adds light risk', () {
      final bright = TriageCalculator.evaluate(
          const TriageInputs(lux: 60000), cfg); // well above brightAboveLux
      final normal =
          TriageCalculator.evaluate(const TriageInputs(lux: 300), cfg);
      expect(bright.score, greaterThan(normal.score));
    });

    test('flags carry the active overrides for the Helper UI', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(
            motionLevel: 0.1, impactDetected: true, batteryLevel: 100),
        cfg,
      );
      expect(r.flags, contains('fall'));
    });

    test('a forced (simulated) rule produces a result even with no sensors', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(),
        TriageConfig.defaults()..forceFall = true,
      );
      expect(r.flags, contains('fall'));
      expect(r.score, greaterThan(0));
      expect(r.note, isNull); // not "running blind" — a real testable result
      expect(r.breakdown.map((p) => p.label), contains('Fall'));
    });

    test('forced battery rules stay mutually exclusive', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(),
        TriageConfig.defaults()
          ..forceCriticalBattery = true
          ..forceLowBattery = true,
      );
      expect(r.flags, contains('criticalBattery'));
      expect(r.flags, isNot(contains('lowBattery')));
    });

    test('healthy battery contributes nothing; low battery escalates', () {
      final healthy =
          TriageCalculator.evaluate(const TriageInputs(batteryLevel: 80), cfg);
      expect(healthy.score, 0.0); // above comfort, not charging-relevant
      final dying =
          TriageCalculator.evaluate(const TriageInputs(batteryLevel: 5), cfg);
      expect(dying.tier, 'Critical'); // low + critical battery boosts
    });

    test('score is clamped to the configured cap', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(
          motionLevel: 0.0,
          impactDetected: true,
          faintedSuspected: true,
          batteryLevel: 2,
        ),
        cfg,
      );
      expect(r.score, lessThanOrEqualTo(cfg.scoreCap));
      expect(r.score, cfg.scoreCap); // this scenario maxes out
    });

    test('charging suppresses battery urgency and its boosts', () {
      final discharging = TriageCalculator.evaluate(
          const TriageInputs(batteryLevel: 15, batteryDrainPerMin: 1.0), cfg);
      final charging = TriageCalculator.evaluate(
          const TriageInputs(
              batteryLevel: 15, batteryDrainPerMin: 1.0, batteryCharging: true),
          cfg);
      expect(charging.score, lessThan(discharging.score));
    });

    test('disabling the fall rule removes its boost', () {
      const inputs = TriageInputs(
          motionLevel: 0.5, impactDetected: true, batteryLevel: 100);
      final withFall = TriageCalculator.evaluate(inputs, cfg);
      final noFall = TriageCalculator.evaluate(
          inputs, TriageConfig.defaults()..fallEnabled = false);
      expect(noFall.score, lessThan(withFall.score));
    });

    test('tiers use plain point thresholds', () {
      expect(TriageCalculator.tierForScore(80, cfg), 'Critical');
      expect(TriageCalculator.tierForScore(60, cfg), 'High');
      expect(TriageCalculator.tierForScore(30, cfg), 'Moderate');
      expect(TriageCalculator.tierForScore(10, cfg), 'Low');
    });

    test('breakdown lists each contributor and only persists 4 sensors', () {
      final r = TriageCalculator.evaluate(
        const TriageInputs(
          motionLevel: 0.0,
          impactDetected: true,
          micDecibel: 80,
          pressureDeviation: 3,
          batteryLevel: 50,
          lux: 1,
          proximityNear: true,
        ),
        cfg,
      );
      expect(r.breakdown, isNotEmpty);
      expect(r.normalised.keys, everyElement(isIn(TriageSensor.all)));
      expect(r.normalised.keys, containsAll([
        TriageSensor.accelerometer,
        TriageSensor.barometer,
        TriageSensor.microphone,
        TriageSensor.battery,
      ]));
    });
  });
}
