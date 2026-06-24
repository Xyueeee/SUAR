import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Runtime-editable triage tuning. Replaces compile-time constants so scoring
/// can be tuned (and reset) live from the in-app Triage Logic page.
///
/// Model is **additive points**: each sensor adds `weight × risk` points and
/// enabled safety rules add flat boosts on top, so the total can exceed 100.
/// Normalisers are calibrated so a NORMAL reading contributes ~0 — only
/// abnormal readings add points, so a calm phone scores near zero.
///
/// Mutable on purpose — the editor binds sliders straight to these fields.
class TriageConfig {
  TriageConfig({
    required this.wMotion,
    required this.wBattery,
    required this.wMic,
    required this.wBarometer,
    required this.wLight,
    required this.wProximity,
    required this.scoreCap,
    required this.criticalThreshold,
    required this.highThreshold,
    required this.moderateThreshold,
    required this.fallEnabled,
    required this.fallBoost,
    required this.fallLatchSeconds,
    required this.faintEnabled,
    required this.faintBoost,
    required this.faintImmobileSeconds,
    required this.lowBatteryEnabled,
    required this.lowBatteryThreshold,
    required this.lowBatteryBoost,
    required this.criticalBatteryEnabled,
    required this.criticalBatteryThreshold,
    required this.criticalBatteryBoost,
    required this.batteryComfortLevel,
    required this.pressureMaxDeviationHpa,
    required this.micMinDb,
    required this.micMaxDb,
    required this.darkBelowLux,
    required this.brightAboveLux,
    required this.batteryFastDrainPerMin,
    this.forceFall = false,
    this.forceFaint = false,
    this.forceLowBattery = false,
    this.forceCriticalBattery = false,
  });

  // Sensor weights (points contributed at full risk).
  double wMotion;
  double wBattery;
  double wMic;
  double wBarometer;
  double wLight;
  double wProximity;

  // The score is clamped to this cap (the sum of all sensor weights = 100 by
  // default), so the number stays on a clean, comparable 0..cap scale even
  // though the raw additive total can run higher.
  double scoreCap;

  // Tier thresholds (points, on the 0..scoreCap scale).
  double criticalThreshold;
  double highThreshold;
  double moderateThreshold;

  // Fall rule + how long a detected impact stays "latched" so a momentary
  // spike keeps counting for a while instead of vanishing next cycle.
  bool fallEnabled;
  double fallBoost;
  double fallLatchSeconds;

  // Faint rule: an impact followed by no movement for an extended period
  // (suspected unconscious) — the stronger escalation.
  bool faintEnabled;
  double faintBoost;
  double faintImmobileSeconds;

  // Battery rules.
  bool lowBatteryEnabled;
  double lowBatteryThreshold; // %
  double lowBatteryBoost;
  bool criticalBatteryEnabled;
  double criticalBatteryThreshold; // %
  double criticalBatteryBoost;

  // Continuous battery risk stays ~0 above this level (a healthy battery is not
  // a distress signal); it ramps up only as the charge falls below it.
  double batteryComfortLevel; // %

  // Debug "simulate" switches — force a rule's condition true regardless of the
  // real sensors, so the full victim→helper flow (boost + flag + map pin) can
  // be tested without actually dropping the phone or draining the battery.
  // Distinct from the enable toggles (which turn the rule OFF entirely). Leave
  // these false in normal use.
  bool forceFall;
  bool forceFaint;
  bool forceLowBattery;
  bool forceCriticalBattery;

  // Normalisation ranges (per-sensor risk knobs).
  double pressureMaxDeviationHpa;
  double micMinDb; // ambient at/below this ⇒ no mic risk
  double micMaxDb; // loud at/above this ⇒ full mic risk
  double darkBelowLux; // light risk when darker than this (trapped/buried)
  double brightAboveLux; // light risk when brighter than this (exposed to sun)
  double batteryFastDrainPerMin;

  factory TriageConfig.defaults() => TriageConfig(
        wMotion: 38,
        wBattery: 22,
        wMic: 18,
        wBarometer: 12,
        wLight: 6,
        wProximity: 4,
        // Cap with headroom so stacked severe signals still differentiate
        // (a faint scenario lands well above Critical rather than pinning).
        scoreCap: 150,
        criticalThreshold: 75,
        highThreshold: 50,
        moderateThreshold: 25,
        fallEnabled: true,
        fallBoost: 25, // a responsive fall ⇒ ~Moderate/High
        fallLatchSeconds: 45,
        faintEnabled: true,
        faintBoost: 55, // fall + faint ⇒ Critical (unconscious)
        faintImmobileSeconds: 20,
        lowBatteryEnabled: true,
        lowBatteryThreshold: 30,
        lowBatteryBoost: 40,
        criticalBatteryEnabled: true,
        criticalBatteryThreshold: 15,
        criticalBatteryBoost: 80, // alone reaches Critical (comms dying)
        batteryComfortLevel: 40,
        pressureMaxDeviationHpa: 5,
        micMinDb: 55, // typical room ambient ⇒ no risk
        micMaxDb: 90,
        darkBelowLux: 40, // a lit room contributes nothing
        brightAboveLux: 25000, // direct-sun exposure
        batteryFastDrainPerMin: 2,
      );

  Map<String, dynamic> toJson() => {
        'wMotion': wMotion,
        'wBattery': wBattery,
        'wMic': wMic,
        'wBarometer': wBarometer,
        'wLight': wLight,
        'wProximity': wProximity,
        'scoreCap': scoreCap,
        'criticalThreshold': criticalThreshold,
        'highThreshold': highThreshold,
        'moderateThreshold': moderateThreshold,
        'fallEnabled': fallEnabled,
        'fallBoost': fallBoost,
        'fallLatchSeconds': fallLatchSeconds,
        'faintEnabled': faintEnabled,
        'faintBoost': faintBoost,
        'faintImmobileSeconds': faintImmobileSeconds,
        'lowBatteryEnabled': lowBatteryEnabled,
        'lowBatteryThreshold': lowBatteryThreshold,
        'lowBatteryBoost': lowBatteryBoost,
        'criticalBatteryEnabled': criticalBatteryEnabled,
        'criticalBatteryThreshold': criticalBatteryThreshold,
        'criticalBatteryBoost': criticalBatteryBoost,
        'batteryComfortLevel': batteryComfortLevel,
        'pressureMaxDeviationHpa': pressureMaxDeviationHpa,
        'micMinDb': micMinDb,
        'micMaxDb': micMaxDb,
        'darkBelowLux': darkBelowLux,
        'brightAboveLux': brightAboveLux,
        'batteryFastDrainPerMin': batteryFastDrainPerMin,
        'forceFall': forceFall,
        'forceFaint': forceFaint,
        'forceLowBattery': forceLowBattery,
        'forceCriticalBattery': forceCriticalBattery,
      };

  /// Tolerant of missing keys (older saved configs) — falls back to defaults
  /// field by field so a new knob never corrupts a stored config.
  factory TriageConfig.fromJson(Map<String, dynamic> j) {
    final d = TriageConfig.defaults();
    double n(String k, double f) => (j[k] as num?)?.toDouble() ?? f;
    bool b(String k, bool f) => j[k] as bool? ?? f;
    return TriageConfig(
      wMotion: n('wMotion', d.wMotion),
      wBattery: n('wBattery', d.wBattery),
      wMic: n('wMic', d.wMic),
      wBarometer: n('wBarometer', d.wBarometer),
      wLight: n('wLight', d.wLight),
      wProximity: n('wProximity', d.wProximity),
      scoreCap: n('scoreCap', d.scoreCap),
      criticalThreshold: n('criticalThreshold', d.criticalThreshold),
      highThreshold: n('highThreshold', d.highThreshold),
      moderateThreshold: n('moderateThreshold', d.moderateThreshold),
      fallEnabled: b('fallEnabled', d.fallEnabled),
      fallBoost: n('fallBoost', d.fallBoost),
      fallLatchSeconds: n('fallLatchSeconds', d.fallLatchSeconds),
      faintEnabled: b('faintEnabled', d.faintEnabled),
      faintBoost: n('faintBoost', d.faintBoost),
      faintImmobileSeconds: n('faintImmobileSeconds', d.faintImmobileSeconds),
      lowBatteryEnabled: b('lowBatteryEnabled', d.lowBatteryEnabled),
      lowBatteryThreshold: n('lowBatteryThreshold', d.lowBatteryThreshold),
      lowBatteryBoost: n('lowBatteryBoost', d.lowBatteryBoost),
      criticalBatteryEnabled:
          b('criticalBatteryEnabled', d.criticalBatteryEnabled),
      criticalBatteryThreshold:
          n('criticalBatteryThreshold', d.criticalBatteryThreshold),
      criticalBatteryBoost: n('criticalBatteryBoost', d.criticalBatteryBoost),
      batteryComfortLevel: n('batteryComfortLevel', d.batteryComfortLevel),
      pressureMaxDeviationHpa:
          n('pressureMaxDeviationHpa', d.pressureMaxDeviationHpa),
      micMinDb: n('micMinDb', d.micMinDb),
      micMaxDb: n('micMaxDb', d.micMaxDb),
      darkBelowLux: n('darkBelowLux', d.darkBelowLux),
      brightAboveLux: n('brightAboveLux', d.brightAboveLux),
      batteryFastDrainPerMin:
          n('batteryFastDrainPerMin', d.batteryFastDrainPerMin),
      forceFall: b('forceFall', d.forceFall),
      forceFaint: b('forceFaint', d.forceFaint),
      forceLowBattery: b('forceLowBattery', d.forceLowBattery),
      forceCriticalBattery: b('forceCriticalBattery', d.forceCriticalBattery),
    );
  }

  // --- Persistence + the live active instance ------------------------------
  static const String _prefsKey = 'suar_triage_config';

  /// The config the running triage uses. Edits apply on the next recompute.
  static TriageConfig active = TriageConfig.defaults();

  static Future<TriageConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        active = TriageConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      active = TriageConfig.defaults();
    }
    return active;
  }

  Future<void> save() async {
    active = this;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  static Future<TriageConfig> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    active = TriageConfig.defaults();
    return active;
  }
}
