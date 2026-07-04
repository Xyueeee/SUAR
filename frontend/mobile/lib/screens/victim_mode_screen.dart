import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:torch_light/torch_light.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../constants.dart';
import '../controllers/victim_controller.dart';
import '../help/help_tour.dart';
import '../log_translator.dart';
import '../services/app_lock.dart';
import '../theme.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mesh_activity_card.dart';
import '../widgets/radio_status_banner.dart';
import 'dashboard_screen.dart';
import 'doc_screen.dart';

enum _TorchMode { off, normal, sos }

// SOS Morse: · · · (S) — — — (O) · · · (S)
const _kSosPattern = <(bool, int)>[
  (true, 200), (false, 200), (true, 200), (false, 200), (true, 200), (false, 600),
  (true, 600), (false, 200), (true, 600), (false, 200), (true, 600), (false, 600),
  (true, 200), (false, 200), (true, 200), (false, 200), (true, 200), (false, 2000),
];

// Dark theme applied to content screens opened from victim mode.
// Matches the OLED-black aesthetic of the victim/helper screens.
// All sub-screens pushed by DocScreen also inherit this via _pushWithTheme.
final _kVictimDocTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.black,
  colorScheme: const ColorScheme.dark(
    surface: Color(0xFF111111),
    primary: Color(0xFF3E6FA8),
    secondary: Color(0xFF3E6FA8),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    elevation: 0,
  ),
  checkboxTheme: CheckboxThemeData(
    fillColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.selected) ? const Color(0xFF62E24B) : null,
    ),
    side: const BorderSide(color: Colors.white38, width: 2),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(linearMinHeight: 11.0),
  dividerTheme: const DividerThemeData(color: Colors.white12),
);

/// Returns a doc theme with [VictimRadioStatus] injected so the radio status
/// pill is visible in every DocScreen AppBar opened from victim mode.
ThemeData _victimDocThemeWith(ValueListenable<String> radioLabel) =>
    _kVictimDocTheme.copyWith(extensions: [VictimRadioStatus(radioLabel)]);

Color _tierColor(String tier) => switch (tier) {
  'Critical' => Colors.redAccent,
  'High'     => Colors.orangeAccent,
  'Moderate' => Colors.amber,
  'Low'      => Colors.lightGreenAccent,
  _          => Colors.white54,
};

/// "4.1.3 SUAR Emergency Mode - Victim Mode" (Figma node 7:847).
class VictimModeScreen extends StatefulWidget {
  const VictimModeScreen({super.key});

  @override
  State<VictimModeScreen> createState() => _VictimModeScreenState();
}

class _VictimModeScreenState extends State<VictimModeScreen> {
  final VictimController _controller = VictimController();
  final List<LogEntry> _rawLog = [];
  final List<LogEntry> _displayLog = [];
  String? _lastDisplayedTriage;
  DateTime? _lastNoHelpersShown;
  StreamSubscription<String>? _statusSub;

  // Live triage from controller
  ({String tier, int points, List<String> flags})? _triage;

  // Compass
  StreamSubscription<MagnetometerEvent>? _magSub;
  double _bearing = 0;     // smoothed 0–360, 0 = magnetic north (phone top)
  double _rawBearing = 0;  // last raw sample, for EMA reference
  bool _compassPaused = false;

  // Tools card PageView
  final _toolsPageCtrl = PageController();
  int _toolsPage = 0;

  // Torch
  _TorchMode _torchMode = _TorchMode.off;
  Timer? _sosTimer;
  int _sosStep = 0;

  // Help tour targets
  final _kRadioPill = GlobalKey();
  final _kMeshCard = GlobalKey();
  final _kTipsCard = GlobalKey();
  final _kToolsCard = GlobalKey();
  late final HelpTourController _help;

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
    _statusSub = _controller.statusStream.listen(_addLogLine);
    _controller.triageStatus.addListener(_onTriage);
    _controller.startVictimMode();
    _startMagnetometer();
    _help = HelpTourController([
      HelpStep(
        targetKey: _kRadioPill,
        title: 'Your connection status',
        body: const [
          'Broadcasting means nearby helpers can find you.',
          'It moves through Connecting to Sending as a helper picks up your signal.',
        ],
      ),
      HelpStep(
        targetKey: _kMeshCard,
        title: 'Live activity',
        body: const [
          'Shows what your phone is doing right now, in plain language.',
          'You do not need to do anything here, it updates on its own.',
        ],
      ),
      HelpStep(
        targetKey: _kToolsCard,
        title: 'Survival tools',
        body: const [
          'Flashlight (with an SOS blink) and a compass.',
          'Swipe sideways for your ID, medical info, and live triage.',
          'These keep working while you broadcast.',
        ],
      ),
      HelpStep(
        targetKey: _kTipsCard,
        title: 'Survival & first aid tips',
        body: const [
          'Quick reference for staying safe and helping the injured.',
          'Works fully offline once loaded.',
        ],
      ),
    ]);
  }

  void _addLogLine(String raw) {
    if (!mounted) return;
    setState(() {
      _rawLog.add(LogEntry(raw));
      final translated = translateLog(raw);
      if (translated == null) return;
      if (translated.startsWith('Triage updated:')) {
        if (translated == _lastDisplayedTriage) return;
        _lastDisplayedTriage = translated;
      }
      if (translated == 'No helpers detected nearby. Still searching…') {
        final now = DateTime.now();
        if (_lastNoHelpersShown != null &&
            now.difference(_lastNoHelpersShown!).inSeconds < 12) { return; }
        _lastNoHelpersShown = now;
      }
      _displayLog.add(LogEntry(translated));
    });
  }

  void _startMagnetometer() {
    _magSub?.cancel();
    // SensorInterval.uiInterval ≈ 66 ms / ~15 Hz.
    // EMA on shortest arc: prevents wrap-around flip and damps sensor jitter.
    // α=0.12 → ~0.5s settling time at 15 Hz (the "gas cushion" damping feel).
    _magSub = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
      (e) {
        _rawBearing = (math.atan2(e.x, e.y) * 180 / math.pi + 360) % 360;
        // Shortest-arc diff so crossing 0°/360° doesn't spin the needle.
        double diff = (_rawBearing - _bearing + 540) % 360 - 180;
        // Dead zone: ignore sub-1.5° noise (noisy magnetometers like OPPO A96).
        if (diff.abs() < 1.5) return;
        // α=0.06 → ~1s settling at 15 Hz; smoother than 0.12 for jittery chips.
        final smoothed = (_bearing + diff * 0.06 + 360) % 360;
        if (mounted) setState(() => _bearing = smoothed);
      },
      onError: (_) {},
    );
  }

  void _toggleCompassPause() {
    if (_compassPaused) {
      setState(() => _compassPaused = false);
      _startMagnetometer(); // resumes hardware sampling
    } else {
      _magSub?.cancel(); // cancels HAL subscription — stops hardware polling
      _magSub = null;
      setState(() => _compassPaused = true);
    }
  }

  void _onTriage() {
    if (!mounted) return;
    setState(() => _triage = _controller.triageStatus.value);
  }

  @override
  void dispose() {
    _help.dispose();
    _statusSub?.cancel();
    _controller.triageStatus.removeListener(_onTriage);
    _magSub?.cancel();
    _sosTimer?.cancel();
    _toolsPageCtrl.dispose();
    TorchLight.disableTorch().catchError((_) {});
    unawaited(WakelockPlus.disable());
    unawaited(_controller.stopVictimMode().whenComplete(_controller.dispose));
    super.dispose();
  }

  // ─── Torch ─────────────────────────────────────────────────────────────────

  Future<void> _toggleNormal() async {
    _sosTimer?.cancel();
    if (_torchMode == _TorchMode.normal) {
      try { await TorchLight.disableTorch(); } catch (_) {}
      setState(() => _torchMode = _TorchMode.off);
    } else {
      try {
        await TorchLight.enableTorch();
        setState(() => _torchMode = _TorchMode.normal);
      } catch (_) {}
    }
  }

  void _toggleSos() {
    _sosTimer?.cancel();
    if (_torchMode == _TorchMode.sos) {
      TorchLight.disableTorch().catchError((_) {});
      setState(() => _torchMode = _TorchMode.off);
      return;
    }
    TorchLight.disableTorch().catchError((_) {});
    setState(() { _torchMode = _TorchMode.sos; _sosStep = 0; });
    _stepSos();
  }

  void _stepSos() {
    if (!mounted || _torchMode != _TorchMode.sos) return;
    if (_sosStep >= _kSosPattern.length) _sosStep = 0;
    final (on, ms) = _kSosPattern[_sosStep++];
    (on ? TorchLight.enableTorch() : TorchLight.disableTorch()).catchError((_) {});
    _sosTimer = Timer(Duration(milliseconds: ms), _stepSos);
  }

  // ─── Exit gate ───────────────────────────────────────────────────────────

  /// Leave victim mode. When the exit lock is on, require the device lock first
  /// (fail-open if the device cannot authenticate). Programmatic pop bypasses
  /// [PopScope], so this is the single exit path for both the chevron and the
  /// hardware/predictive back button.
  Future<void> _handleExit() async {
    // If the help tour is open, the back button should close it, not leave
    // victim mode (and definitely not trigger the exit-lock prompt behind it).
    if (_help.isShowing) {
      _help.dismiss();
      return;
    }
    if (AppLock.requireExitVictim.value) {
      final ok = await AppLock.authenticate('Confirm to leave victim mode');
      if (!ok || !mounted) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleExit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 21, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 6),
              const Text(
                'Victim mode is now active.\n\nYour phone is now currently actively broadcasting your SOS signal to all nearby available helpers.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              const RadioStatusBanner(),
              const SizedBox(height: 8),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: detailedLogging,
                  builder: (_, detailed, x) => MeshActivityCard(
                    key: _kMeshCard,
                    lines: detailed ? _rawLog : _displayLog,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _VictimTipsCard(key: _kTipsCard, radioLabel: _controller.radioLabel),
              const SizedBox(height: 8),
              _buildToolsCard(),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        IconButton(
          onPressed: _handleExit,
          icon: const Icon(Icons.chevron_left, color: Colors.white),
        ),
        const Expanded(
          child: MarqueeText(
            'Victim Mode',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 8),
        HelpButton(controller: _help, color: Colors.white70),
        ValueListenableBuilder<String>(
          valueListenable: _controller.radioLabel,
          builder: (ctx, status, _) {
            final dotColor = switch (status) {
              'Sending'    => Colors.amber,
              'Connecting' => const Color(0xFF4CAF50),
              'BT Link'    => const Color(0xFF6AA8D5),
              _            => const Color(0xFFE05555),
            };
            final label = status == 'BT Link' ? 'Connecting' : status;
            return Container(
              key: _kRadioPill,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                  ),
                  const SizedBox(width: 5),
                  Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  // ─── Tools card (PageView) ────────────────────────────────────────────────

  Widget _buildToolsCard() {
    return SizedBox(
      key: _kToolsCard,
      height: 170,
      child: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _toolsPageCtrl,
              onPageChanged: (i) => setState(() => _toolsPage = i),
              children: [
                _buildPage1(),
                _buildPage2(),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < 2; i++)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _toolsPage ? Colors.white70 : Colors.white24,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPage1() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildFlashlightCard()),
        const SizedBox(width: 8),
        Expanded(child: _buildCompassCard()),
      ],
    );
  }

  Widget _buildPage2() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildVictimIdCard()),
              const SizedBox(height: 4),
              Expanded(child: _buildMedicalCard()),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: _buildTriageInfoCard()),
      ],
    );
  }

  Widget _buildVictimIdCard() {
    final id = _controller.deviceId;
    final suffix = id != null ? deviceNameSuffix(id) : '----';
    return Container(
      decoration: BoxDecoration(
        color: kPanelDark,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('YOUR ID',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
          const SizedBox(height: 3),
          Text(
            'Victim-$suffix',
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text('Show this to helpers',
              style: TextStyle(color: Colors.white38, fontSize: 9)),
        ],
      ),
    );
  }

  Widget _buildFlashlightCard() {
    final isNormal = _torchMode == _TorchMode.normal;
    final isSos = _torchMode == _TorchMode.sos;
    return Container(
      decoration: BoxDecoration(
        color: kPanelDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Icon(
                  isNormal || isSos ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                  color: isNormal ? Colors.amber : isSos ? Colors.redAccent : Colors.white30,
                  size: 15,
                ),
                const SizedBox(width: 5),
                const Text('Flashlight',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _toggleNormal,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isNormal
                    ? Colors.amber.withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.07),
                border: Border.all(
                  color: isNormal ? Colors.amber : Colors.white24,
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.flashlight_on_rounded,
                color: isNormal ? Colors.amber : Colors.white24,
                size: 22,
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: GestureDetector(
              onTap: _toggleSos,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  color: isSos ? Colors.red.withValues(alpha: 0.18) : Colors.transparent,
                  border: Border.all(color: isSos ? Colors.redAccent : Colors.white24),
                ),
                child: Center(
                  child: Text(
                    isSos ? '● SOS active' : 'SOS',
                    style: TextStyle(
                      color: isSos ? Colors.redAccent : Colors.white30,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompassCard() {
    return GestureDetector(
      onTap: _toggleCompassPause,
      child: Container(
        decoration: BoxDecoration(
          color: kPanelDark,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Compass',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                Text(
                  _compassPaused ? 'Paused' : '${_bearing.round()}°',
                  style: TextStyle(
                    color: _compassPaused ? Colors.amber : Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Stack(
                  children: [
                    CustomPaint(
                      painter: _CompassPainter(bearing: _bearing),
                      child: const SizedBox.expand(),
                    ),
                    if (_compassPaused)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('Tap to resume',
                              style: TextStyle(color: Colors.amber, fontSize: 9)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedicalCard() {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Theme(
            data: _victimDocThemeWith(_controller.radioLabel),
            child: const MedicalInfoScreen(),
          ),
        ));
      },
      child: Container(
        decoration: BoxDecoration(
          color: kPanelDark,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: const Row(
          children: [
            Icon(Icons.medical_services_outlined, color: Colors.redAccent, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text('Medical Info',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right, color: Colors.white38, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildTriageInfoCard() {
    final t = _triage;
    final tc = t != null ? _tierColor(t.tier) : Colors.white24;
    return Container(
      decoration: BoxDecoration(
        color: kPanelDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: t == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monitor_heart_outlined, color: Colors.white24, size: 22),
                  SizedBox(height: 6),
                  Text('Assessing…',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TRIAGE',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.7)),
                  const SizedBox(height: 5),
                  Text(t.tier,
                      style: TextStyle(
                          color: tc,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          height: 1)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: tc.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${t.points} pts',
                        style: TextStyle(
                            color: tc, fontSize: 10, fontWeight: FontWeight.w600)),
                  ),
                  const Spacer(),
                  ...t.flags.take(2).map((f) => Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: Text(f,
                            style: const TextStyle(color: Colors.white38, fontSize: 9),
                            overflow: TextOverflow.ellipsis),
                      )),
                ],
              ),
            ),
    );
  }
}

// ─── Tips card (dark-themed) ──────────────────────────────────────────────────

class _VictimTipsCard extends StatelessWidget {
  const _VictimTipsCard({super.key, required this.radioLabel});
  final ValueListenable<String> radioLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: kPanelDark,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(context, 'Survival Tips', 'survival'),
          const Divider(height: 1, color: Colors.white24, indent: 16, endIndent: 16),
          _row(context, 'First Aid Tips', 'first_aid'),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String category) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        final theme = _victimDocThemeWith(radioLabel);
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Theme(
            data: theme,
            child: DocScreen(category: category, title: label),
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14))),
            const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
          ],
        ),
      ),
    );
  }
}

// ─── Compass painter ──────────────────────────────────────────────────────────

// Rotating compass rose: the entire rose (N/S/E/W labels + needle) rotates
// so N always points toward magnetic north regardless of phone orientation.
class _CompassPainter extends CustomPainter {
  const _CompassPainter({required this.bearing});
  final double bearing;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy) - 2;

    // Fixed outer ring
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Rotate canvas so the rose tracks magnetic north
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-bearing * math.pi / 180);

    // Minor tick marks (every 10°, skip cardinal positions)
    final minorPaint = Paint()..color = Colors.white.withValues(alpha: 0.18)..strokeWidth = 0.8;
    for (int i = 0; i < 36; i++) {
      if (i % 9 == 0) continue;
      final a = i * 10 * math.pi / 180;
      final s = math.sin(a), c = math.cos(a);
      canvas.drawLine(
        Offset(s * (r - 5), -c * (r - 5)),
        Offset(s * r, -c * r),
        minorPaint,
      );
    }

    // Cardinal direction labels
    _label(canvas, 'N', Offset(0, -(r - 11)), Colors.redAccent, 11, bold: true);
    _label(canvas, 'S', Offset(0, r - 11), Colors.white38, 9);
    _label(canvas, 'E', Offset(r - 11, 0), Colors.white38, 9);
    _label(canvas, 'W', Offset(-(r - 11), 0), Colors.white38, 9);

    // Needle: red tip = north, grey tail = south
    canvas.drawLine(
      Offset.zero, Offset(0, -(r - 18)),
      Paint()..color = Colors.redAccent..strokeWidth = 2.5..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset.zero, Offset(0, r - 22),
      Paint()..color = Colors.white24..strokeWidth = 2..strokeCap = StrokeCap.round,
    );

    // Center pivot dot
    canvas.drawCircle(Offset.zero, 3, Paint()..color = Colors.white54);

    canvas.restore();
  }

  void _label(Canvas canvas, String text, Offset center, Color color, double size,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center.translate(-tp.width / 2, -tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) => old.bearing != bearing;
}
