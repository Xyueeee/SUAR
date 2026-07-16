import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

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

  // The score is clamped to this cap, so PriorityScore stays a clean 0..1
  // (score/cap). Continuous sensors sum to 100 at full risk; safety boosts
  // (fall 25 + faint 55 + critical-battery 80 = up to 160) stack on top, so a
  // worst-case stacked victim runs ~230-260 raw. The cap is pure headroom +
  // the normaliser denominator — it does NOT move tier boundaries (those are
  // absolute point thresholds, all far below the cap). A higher cap just lets
  // the most extreme cases differentiate instead of all pinning at 1.0.
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

  // Faint rule: a fall followed by mostly low movement during this observation
  // window (suspected unconscious) — the stronger escalation.
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
        // Headroom for stacked severe signals: realistic worst case runs
        // ~230-260 raw, so 200 keeps all but the absolute extreme off the 1.0
        // ceiling and differentiating. Tiers unaffected (absolute thresholds).
        scoreCap: 200,
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

  /// Parses the admin's `/triage-config` response (lowercase column names,
  /// distinct from [toJson]'s camelCase local-storage shape). Same
  /// tolerant-of-missing-keys fallback as [fromJson].
  factory TriageConfig.fromServerJson(Map<String, dynamic> j) {
    final d = TriageConfig.defaults();
    double n(String k, double f) => (j[k] as num?)?.toDouble() ?? f;
    bool b(String k, bool f) => j[k] as bool? ?? f;
    return TriageConfig(
      wMotion: n('w_motion', d.wMotion),
      wBattery: n('w_battery', d.wBattery),
      wMic: n('w_mic', d.wMic),
      wBarometer: n('w_barometer', d.wBarometer),
      wLight: n('w_light', d.wLight),
      wProximity: n('w_proximity', d.wProximity),
      scoreCap: n('score_cap', d.scoreCap),
      criticalThreshold: n('critical_threshold', d.criticalThreshold),
      highThreshold: n('high_threshold', d.highThreshold),
      moderateThreshold: n('moderate_threshold', d.moderateThreshold),
      fallEnabled: b('fall_enabled', d.fallEnabled),
      fallBoost: n('fall_boost', d.fallBoost),
      fallLatchSeconds: n('fall_latch_seconds', d.fallLatchSeconds),
      faintEnabled: b('faint_enabled', d.faintEnabled),
      faintBoost: n('faint_boost', d.faintBoost),
      faintImmobileSeconds: n('faint_immobile_seconds', d.faintImmobileSeconds),
      lowBatteryEnabled: b('low_battery_enabled', d.lowBatteryEnabled),
      lowBatteryThreshold: n('low_battery_threshold', d.lowBatteryThreshold),
      lowBatteryBoost: n('low_battery_boost', d.lowBatteryBoost),
      criticalBatteryEnabled:
          b('critical_battery_enabled', d.criticalBatteryEnabled),
      criticalBatteryThreshold:
          n('critical_battery_threshold', d.criticalBatteryThreshold),
      criticalBatteryBoost: n('critical_battery_boost', d.criticalBatteryBoost),
      batteryComfortLevel: n('battery_comfort_level', d.batteryComfortLevel),
      pressureMaxDeviationHpa:
          n('pressure_max_deviation_hpa', d.pressureMaxDeviationHpa),
      micMinDb: n('mic_min_db', d.micMinDb),
      micMaxDb: n('mic_max_db', d.micMaxDb),
      darkBelowLux: n('dark_below_lux', d.darkBelowLux),
      brightAboveLux: n('bright_above_lux', d.brightAboveLux),
      batteryFastDrainPerMin:
          n('battery_fast_drain_per_min', d.batteryFastDrainPerMin),
    );
  }

  // --- Persistence + the live active instance ------------------------------
  static const String _prefsKey = 'suar_triage_config';

  // Last admin default this device has ever seen (opportunistic pull, cached
  // for offline use — same pattern as GeofenceService). Null until the first
  // successful fetch or cache load.
  static const String _remoteDefaultKey = 'suar_triage_remote_default';
  static TriageConfig? remoteDefault;

  /// The config the running triage uses. Edits apply on the next recompute.
  static TriageConfig active = TriageConfig.defaults();

  /// Precedence: a device's own local Triage Logic edits always win over the
  /// admin-pushed default (least-surprising for a tester who dialled in
  /// their own values); the admin default only applies where there is no
  /// local override. Fast + offline-safe: reads cached prefs only, never
  /// hits the network (that's [fetchRemoteDefault]'s job).
  static Future<TriageConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawRemote = prefs.getString(_remoteDefaultKey);
      if (rawRemote != null) {
        remoteDefault =
            TriageConfig.fromJson(jsonDecode(rawRemote) as Map<String, dynamic>);
      }
    } catch (_) {/* corrupt cache — ignore, fall through to hardcoded */}

    try {
      final raw = prefs.getString(_prefsKey);
      active = raw != null
          ? TriageConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>)
          : (remoteDefault ?? TriageConfig.defaults());
    } catch (_) {
      active = remoteDefault ?? TriageConfig.defaults();
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

  static Future<String?> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(backendSyncUrlPrefKey)?.trim();
    if (u == null || u.isEmpty) return null;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// Live pull of the admin default. On success, caches it for offline use
  /// and — if this device has no local override — applies it to [active]
  /// immediately (evaluate() reads [active] fresh every cycle, so this is
  /// safe to mutate live). Returns null on any failure (no URL, offline,
  /// bad response); callers already treat that as "use the cache instead".
  static Future<TriageConfig?> fetchRemoteDefault() async {
    final base = await _baseUrl();
    if (base == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('$base/triage-config'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final cfg = TriageConfig.fromServerJson(decoded.cast<String, dynamic>());
      remoteDefault = cfg;
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(cfg.toJson());
      // Only act on an actual admin change. This runs every 60s while the
      // Dashboard is open — unconditionally swapping [active] would detach a
      // Triage Logic session mid-edit (the screen holds the old instance
      // until its next _persist), and rewriting identical prefs every poll
      // is pointless churn.
      if (prefs.getString(_remoteDefaultKey) != encoded) {
        await prefs.setString(_remoteDefaultKey, encoded);
        if (prefs.getString(_prefsKey) == null) {
          active = cfg; // no local override — admin default applies live
        }
      }
      return cfg;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// What "Reset" should revert to: the freshest reachable admin default,
  /// else the last one this device ever saw, else the hardcoded factory
  /// defaults — in that order.
  static Future<TriageConfig> resolveEffectiveDefault() async {
    final live = await fetchRemoteDefault();
    return live ?? remoteDefault ?? TriageConfig.defaults();
  }

  /// Clears this device's local override and reverts [active] to the
  /// resolved admin default (see [resolveEffectiveDefault]) — so future
  /// admin pushes apply automatically again, until the user tunes locally.
  static Future<TriageConfig> resetToServerDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    active = await resolveEffectiveDefault();
    return active;
  }
}
