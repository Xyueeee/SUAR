import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../sensing/sensor_fusion_engine.dart';
import '../sensing/triage_calculator.dart';
import '../sensing/triage_config.dart';
import '../widgets/back_chevron.dart';

/// Settings > Debugging Options > Triage Logic. A live tuning console: every
/// weight, threshold and safety rule is editable by slider (tap the number to
/// type it), changes apply on the next recompute and persist. A live readout
/// shows the current score, tier, START category and a per-component
/// breakdown, and each safety rule shows whether it is triggered right now.
class TriageLogicScreen extends StatefulWidget {
  const TriageLogicScreen({super.key});

  @override
  State<TriageLogicScreen> createState() => _TriageLogicScreenState();
}

// Same blue as the Dashboard "Device Test" card, for a uniform accent.
const Color _accent = Color(0xFFA7C7E7);
const Color _accentInk = Color(0xFF3E6FA8); // darker shade for small text/contrast

class _TriageLogicScreenState extends State<TriageLogicScreen> {
  final SensorFusionEngine _engine = SensorFusionEngine();
  TriageConfig _cfg = TriageConfig.active;
  Timer? _tick;
  TriageInputs? _inputs;
  TriageResult? _live;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await TriageConfig.load();
    if (_disposed || !mounted) return;
    setState(() => _cfg = TriageConfig.active);
    final mic = await Permission.microphone.isGranted; // no prompt here
    await _engine.start(withMic: mic);
    if (_disposed) return;
    _tick = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!mounted) return;
      setState(() {
        _inputs = _engine.currentInputs;
        _live = TriageCalculator.evaluate(_inputs!, _cfg);
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _engine.dispose();
    super.dispose();
  }

  void _onChange(VoidCallback mutate) => setState(mutate);
  Future<void> _persist() => _cfg.save();

  ColorScheme get _cs => Theme.of(context).colorScheme;

  Future<void> _resetAll() async {
    if (await _confirm('Reset all triage values?',
        'Restores every weight, tier and rule to defaults.')) {
      await TriageConfig.resetToDefaults();
      if (!mounted) return;
      setState(() => _cfg = TriageConfig.active);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Reset')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).copyWith(
      colorScheme: Theme.of(context).colorScheme.copyWith(primary: _accent),
    );
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Triage Logic'),
        actions: [
          IconButton(
            tooltip: 'Reset all to defaults',
            icon: const Icon(Icons.refresh),
            onPressed: _resetAll,
          ),
        ],
      ),
      body: Theme(
        data: theme,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _liveCard(),
            const SizedBox(height: 20),
            _section(
              'Sensor weights',
              'Points each sensor adds at full risk. A normal reading adds ~0.',
              onReset: () {
                final d = TriageConfig.defaults();
                _cfg
                  ..wMotion = d.wMotion
                  ..wBattery = d.wBattery
                  ..wMic = d.wMic
                  ..wBarometer = d.wBarometer
                  ..wLight = d.wLight
                  ..wProximity = d.wProximity;
              },
              children: [
                _tune('Motion (accel + gyro)', _cfg.wMotion, 0, 50,
                    (v) => _cfg.wMotion = v),
                _tune('Battery', _cfg.wBattery, 0, 50, (v) => _cfg.wBattery = v),
                _tune('Microphone', _cfg.wMic, 0, 50, (v) => _cfg.wMic = v),
                _tune('Barometer', _cfg.wBarometer, 0, 50,
                    (v) => _cfg.wBarometer = v),
                _tune('Ambient light', _cfg.wLight, 0, 50,
                    (v) => _cfg.wLight = v),
                _tune('Proximity', _cfg.wProximity, 0, 50,
                    (v) => _cfg.wProximity = v),
              ],
            ),
            _section(
              'Score & tiers',
              'Score is capped, then classified. Cap defaults to 100 = the sum '
                  'of all sensor weights.',
              onReset: () {
                final d = TriageConfig.defaults();
                _cfg
                  ..scoreCap = d.scoreCap
                  ..criticalThreshold = d.criticalThreshold
                  ..highThreshold = d.highThreshold
                  ..moderateThreshold = d.moderateThreshold;
              },
              children: [
                _tune('Score cap', _cfg.scoreCap, 50, 200,
                    (v) => _cfg.scoreCap = v),
                _tune('Critical at', _cfg.criticalThreshold, 0, 200,
                    (v) => _cfg.criticalThreshold = v),
                _tune('High at', _cfg.highThreshold, 0, 200,
                    (v) => _cfg.highThreshold = v),
                _tune('Moderate at', _cfg.moderateThreshold, 0, 200,
                    (v) => _cfg.moderateThreshold = v),
              ],
            ),
            _section(
              'Safety overrides',
              'Flat point boosts added when their condition is met.',
              onReset: _resetOverrides,
              children: [
                _overrideCard(
                  title: 'Fall detected',
                  triggered: _inputs?.impactDetected ?? false,
                  simulated: _cfg.forceFall,
                  onSimulate: (v) => _cfg.forceFall = v,
                  enabled: _cfg.fallEnabled,
                  onEnabled: (v) => _cfg.fallEnabled = v,
                  onReset: () {
                    final d = TriageConfig.defaults();
                    _cfg
                      ..fallEnabled = d.fallEnabled
                      ..fallBoost = d.fallBoost
                      ..fallLatchSeconds = d.fallLatchSeconds
                      ..forceFall = false;
                  },
                  sliders: [
                    _tune('Adds', _cfg.fallBoost, 0, 80,
                        (v) => _cfg.fallBoost = v),
                    _tune('Stays on for', _cfg.fallLatchSeconds, 5, 180,
                        (v) => _cfg.fallLatchSeconds = v, suffix: ' s'),
                  ],
                ),
                _overrideCard(
                  title: 'Faint (immobile after a fall)',
                  triggered: _inputs?.faintedSuspected ?? false,
                  simulated: _cfg.forceFaint,
                  onSimulate: (v) => _cfg.forceFaint = v,
                  enabled: _cfg.faintEnabled,
                  onEnabled: (v) => _cfg.faintEnabled = v,
                  onReset: () {
                    final d = TriageConfig.defaults();
                    _cfg
                      ..faintEnabled = d.faintEnabled
                      ..faintBoost = d.faintBoost
                      ..faintImmobileSeconds = d.faintImmobileSeconds
                      ..forceFaint = false;
                  },
                  sliders: [
                    _tune('Adds', _cfg.faintBoost, 0, 100,
                        (v) => _cfg.faintBoost = v),
                    _tune('No movement for', _cfg.faintImmobileSeconds, 5, 120,
                        (v) => _cfg.faintImmobileSeconds = v, suffix: ' s'),
                  ],
                ),
                _overrideCard(
                  title: 'Low battery',
                  triggered: _batteryTriggered(_cfg.lowBatteryThreshold),
                  simulated: _cfg.forceLowBattery,
                  onSimulate: (v) {
                    _cfg.forceLowBattery = v;
                    if (v) _cfg.forceCriticalBattery = false; // exclusive
                  },
                  enabled: _cfg.lowBatteryEnabled,
                  onEnabled: (v) => _cfg.lowBatteryEnabled = v,
                  onReset: () {
                    final d = TriageConfig.defaults();
                    _cfg
                      ..lowBatteryEnabled = d.lowBatteryEnabled
                      ..lowBatteryThreshold = d.lowBatteryThreshold
                      ..lowBatteryBoost = d.lowBatteryBoost
                      ..forceLowBattery = false;
                  },
                  sliders: [
                    _tune('When at or below', _cfg.lowBatteryThreshold, 0, 60,
                        (v) => _cfg.lowBatteryThreshold = v, suffix: '%'),
                    _tune('Adds', _cfg.lowBatteryBoost, 0, 80,
                        (v) => _cfg.lowBatteryBoost = v),
                  ],
                ),
                _overrideCard(
                  title: 'Critical battery',
                  triggered: _batteryTriggered(_cfg.criticalBatteryThreshold),
                  simulated: _cfg.forceCriticalBattery,
                  onSimulate: (v) {
                    _cfg.forceCriticalBattery = v;
                    if (v) _cfg.forceLowBattery = false; // exclusive
                  },
                  enabled: _cfg.criticalBatteryEnabled,
                  onEnabled: (v) => _cfg.criticalBatteryEnabled = v,
                  onReset: () {
                    final d = TriageConfig.defaults();
                    _cfg
                      ..criticalBatteryEnabled = d.criticalBatteryEnabled
                      ..criticalBatteryThreshold = d.criticalBatteryThreshold
                      ..criticalBatteryBoost = d.criticalBatteryBoost
                      ..forceCriticalBattery = false;
                  },
                  sliders: [
                    _tune('When at or below', _cfg.criticalBatteryThreshold, 0,
                        40, (v) => _cfg.criticalBatteryThreshold = v,
                        suffix: '%'),
                    _tune('Adds', _cfg.criticalBatteryBoost, 0, 120,
                        (v) => _cfg.criticalBatteryBoost = v),
                  ],
                ),
                Text(
                  'Battery rules only fire while discharging.',
                  style: TextStyle(
                      color: _cs.onSurface.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ),
            _section(
              'Normalisation ranges',
              'Where each raw reading reaches full risk (and where it reads as '
                  'normal).',
              onReset: () {
                final d = TriageConfig.defaults();
                _cfg
                  ..batteryComfortLevel = d.batteryComfortLevel
                  ..pressureMaxDeviationHpa = d.pressureMaxDeviationHpa
                  ..micMinDb = d.micMinDb
                  ..micMaxDb = d.micMaxDb
                  ..darkBelowLux = d.darkBelowLux
                  ..batteryFastDrainPerMin = d.batteryFastDrainPerMin;
              },
              children: [
                _tune('Battery healthy above', _cfg.batteryComfortLevel, 10, 80,
                    (v) => _cfg.batteryComfortLevel = v, suffix: '%'),
                _tune('Pressure: full risk at', _cfg.pressureMaxDeviationHpa, 1,
                    20, (v) => _cfg.pressureMaxDeviationHpa = v, suffix: ' hPa'),
                _tune('Mic: quiet floor', _cfg.micMinDb, 0, 80,
                    (v) => _cfg.micMinDb = v, suffix: ' dB'),
                _tune('Mic: loud ceiling', _cfg.micMaxDb, 50, 120,
                    (v) => _cfg.micMaxDb = v, suffix: ' dB'),
                _tune('Light: dark below', _cfg.darkBelowLux, 5, 200,
                    (v) => _cfg.darkBelowLux = v, suffix: ' lx'),
                _tune('Battery: fast drain at', _cfg.batteryFastDrainPerMin, 0.5,
                    5, (v) => _cfg.batteryFastDrainPerMin = v,
                    suffix: ' %/min', decimals: 1),
              ],
            ),
            const SizedBox(height: 8),
            _methodologyNote(),
          ],
        ),
      ),
    );
  }

  void _resetOverrides() {
    final d = TriageConfig.defaults();
    _cfg
      ..fallEnabled = d.fallEnabled
      ..fallBoost = d.fallBoost
      ..fallLatchSeconds = d.fallLatchSeconds
      ..faintEnabled = d.faintEnabled
      ..faintBoost = d.faintBoost
      ..faintImmobileSeconds = d.faintImmobileSeconds
      ..lowBatteryEnabled = d.lowBatteryEnabled
      ..lowBatteryThreshold = d.lowBatteryThreshold
      ..lowBatteryBoost = d.lowBatteryBoost
      ..criticalBatteryEnabled = d.criticalBatteryEnabled
      ..criticalBatteryThreshold = d.criticalBatteryThreshold
      ..criticalBatteryBoost = d.criticalBatteryBoost
      ..forceFall = false
      ..forceFaint = false
      ..forceLowBattery = false
      ..forceCriticalBattery = false;
  }

  bool _batteryTriggered(double threshold) {
    final i = _inputs;
    if (i == null || i.batteryLevel == null) return false;
    return !i.batteryCharging && i.batteryLevel! <= threshold;
  }

  // --- Live readout --------------------------------------------------------

  Widget _liveCard() {
    final live = _live;
    final tier = live?.tier ?? '—';
    final color = _tierColor(tier);
    final cs = _cs;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 12, height: 12,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text('Live triage',
                  style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.54),
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                live == null ? '' : '${live.score.round()} / ${_cfg.scoreCap.round()} pts',
                style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.87),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            live == null ? 'Sampling…' : tier,
            style: TextStyle(
                color: color, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          if (live != null)
            Text(_startLabel(tier),
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 12)),
          if (live?.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(live!.note!,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 12)),
            ),
          if (live != null && live.breakdown.isNotEmpty) ...[
            const Divider(height: 18),
            for (final part in live.breakdown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.87), fontSize: 13),
                          children: [
                            TextSpan(text: part.label),
                            if (part.detail.isNotEmpty)
                              TextSpan(
                                text: '  ${part.detail}',
                                style: TextStyle(
                                    color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      '+${part.points.toStringAsFixed(part.points < 10 ? 1 : 0)}',
                      style: TextStyle(
                          color: part.points > 0 ? _accentInk : cs.onSurface.withValues(alpha: 0.38),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _startLabel(String tier) => switch (tier) {
        'Critical' => 'START: Immediate (Red)',
        'High' => 'START: urgent (Delayed)',
        'Moderate' => 'START: Delayed (Yellow)',
        'Low' => 'START: Minor (Green)',
        _ => '',
      };

  Color _tierColor(String tier) => switch (tier) {
        'Critical' => const Color(0xFFD64545),
        'High' => const Color(0xFFEC7A1C),
        'Moderate' => const Color(0xFFE0A500),
        'Low' => const Color(0xFF3FB836),
        _ => _cs.onSurface.withValues(alpha: 0.54),
      };

  Widget _methodologyNote() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Tiers follow START rapid-triage categories. Phone sensors only '
          'approximate the assessment. A fall followed by no movement stands '
          'in for "unresponsive / not walking" (Immediate), while battery is a '
          'comms-survival signal for the offline mesh, not a medical vital. '
          'This is a screening aid, not a medical diagnosis.',
          style: TextStyle(
              color: _cs.onSurface.withValues(alpha: 0.6),
              fontSize: 12,
              height: 1.4),
        ),
      );

  // --- Editing widgets -----------------------------------------------------

  Widget _section(String title, String subtitle,
      {required VoidCallback onReset, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: _cs.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            color: _cs.onSurface.withValues(alpha: 0.55),
                            fontSize: 12)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  _onChange(onReset);
                  _persist();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reset'),
                style: TextButton.styleFrom(foregroundColor: _accentInk),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  Widget _tune(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> apply, {
    String suffix = '',
    int decimals = 0,
  }) {
    final shown =
        decimals > 0 ? value.toStringAsFixed(decimals) : value.round().toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(color: _cs.onSurface.withValues(alpha: 0.87), fontSize: 14)),
              ),
              // Tap the value to type it directly.
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () async {
                  final v = await _promptNumber(label, value, min, max, decimals);
                  if (v != null) {
                    _onChange(() => apply(v));
                    await _persist();
                  }
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('$shown$suffix',
                      style: const TextStyle(
                          color: _accentInk,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) =>
                  _onChange(() => apply(decimals > 0 ? v : v.roundToDouble())),
              onChangeEnd: (_) => _persist(),
            ),
          ),
        ],
      ),
    );
  }

  Future<double?> _promptNumber(
      String label, double current, double min, double max, int decimals) {
    return showDialog<double>(
      context: context,
      builder: (c) => _PromptNumberDialog(
        label: label,
        current: current,
        min: min,
        max: max,
        decimals: decimals,
      ),
    );
  }

  Widget _overrideCard({
    required String title,
    required bool triggered,
    required bool enabled,
    required ValueChanged<bool> onEnabled,
    required VoidCallback onReset,
    required List<Widget> sliders,
    bool simulated = false,
    ValueChanged<bool>? onSimulate,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 8),
      decoration: BoxDecoration(
        color: _cs.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: _cs.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              _TriggerBadge(triggered: (triggered || simulated) && enabled),
              Switch(
                value: enabled,
                onChanged: (v) {
                  _onChange(() => onEnabled(v));
                  _persist();
                },
              ),
              IconButton(
                tooltip: 'Reset this rule',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () {
                  _onChange(onReset);
                  _persist();
                },
              ),
            ],
          ),
          if (enabled && onSimulate != null)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: Row(
                children: [
                  const Icon(Icons.bolt, size: 16, color: _accentInk),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('Simulate trigger (for testing)',
                        style: TextStyle(color: _cs.onSurface.withValues(alpha: 0.54), fontSize: 13)),
                  ),
                  SizedBox(
                    height: 28,
                    child: OutlinedButton(
                      onPressed: () {
                        _onChange(() => onSimulate(!simulated));
                        _persist();
                      },
                      style: OutlinedButton.styleFrom(
                        backgroundColor:
                            simulated ? _accentInk.withValues(alpha: 0.12) : null,
                        foregroundColor: simulated ? _accentInk : _cs.onSurface.withValues(alpha: 0.54),
                        side: BorderSide(
                            color: simulated ? _accentInk : _cs.onSurface.withValues(alpha: 0.26)),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 28),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(simulated ? 'Simulating' : 'Simulate'),
                    ),
                  ),
                ],
              ),
            ),
          if (enabled) ...sliders,
        ],
      ),
    );
  }
}

String _fmtNum(double v, int decimals) =>
    decimals > 0 ? v.toStringAsFixed(decimals) : v.round().toString();

/// Numeric override dialog used by [_TriageLogicScreenState._promptNumber].
/// Owns its [TextEditingController] as a State field (not disposed manually
/// after `showDialog` resolves) — the dialog route keeps rebuilding for
/// several frames during its exit transition, so disposing the controller
/// right after `await showDialog` returns crashes mid-animation.
class _PromptNumberDialog extends StatefulWidget {
  const _PromptNumberDialog({
    required this.label,
    required this.current,
    required this.min,
    required this.max,
    required this.decimals,
  });

  final String label;
  final double current;
  final double min;
  final double max;
  final int decimals;

  @override
  State<_PromptNumberDialog> createState() => _PromptNumberDialogState();
}

class _PromptNumberDialogState extends State<_PromptNumberDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.decimals > 0
        ? widget.current.toStringAsFixed(widget.decimals)
        : widget.current.round().toString(),
  );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = double.tryParse(_ctrl.text.trim());
    if (parsed == null) {
      setState(() => _error = 'Enter a number');
      return;
    }
    if (parsed < widget.min || parsed > widget.max) {
      setState(() =>
          _error = 'Must be ${_fmtNum(widget.min, widget.decimals)}–${_fmtNum(widget.max, widget.decimals)}');
      return;
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.label),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals > 0),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        // Same rounded grey box + blue focus as showValidatedTextDialog.
        decoration: InputDecoration(
          helperText:
              'Allowed: ${_fmtNum(widget.min, widget.decimals)} – ${_fmtNum(widget.max, widget.decimals)}',
          errorText: _error,
          filled: true,
          fillColor: cs.onSurface.withValues(alpha: 0.06),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.transparent),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.transparent),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _accent, width: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}

class _TriggerBadge extends StatelessWidget {
  const _TriggerBadge({required this.triggered});
  final bool triggered;

  @override
  Widget build(BuildContext context) {
    final color = triggered
        ? const Color(0xFFD64545)
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 5),
          Text(triggered ? 'Triggered' : 'Idle',
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
