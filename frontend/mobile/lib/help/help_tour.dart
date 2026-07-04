import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Contextual help: a manual, multi-step coach-mark tour. Each screen supplies a
/// list of [HelpStep]s pointing at real widgets (via GlobalKey). Tapping a "?"
/// icon calls [HelpTourController.start], which dims the screen and spotlights
/// one widget at a time with an explanation card.
///
/// Pure Flutter (CustomPainter + Overlay), no package, fine under minSdk 24.

/// One step of a tour. [targetKey] must be attached to a real, laid-out widget.
/// If [targetKey] is null (or its widget is not in the tree when the tour runs)
/// the step is shown as a centered card with no spotlight (useful for intro or
/// summary steps that describe the whole screen).
class HelpStep {
  const HelpStep({
    this.targetKey,
    required this.title,
    required this.body,
    this.circle = false,
    this.ensureVisible,
  });

  /// Widget to spotlight. Null = centered card, no cutout.
  final GlobalKey? targetKey;
  final String title;

  /// Short lines of plain-language explanation.
  final List<String> body;

  /// Punch a circular hole instead of a rounded rectangle (for icon targets).
  final bool circle;

  /// Optional callback run before measuring the target: scroll or page-animate
  /// so the target is on-screen. Should complete quickly; the overlay waits one
  /// frame after it before measuring.
  final Future<void> Function()? ensureVisible;
}

/// Drives a single tour. Create with a step list, call [start] from a button.
/// Idempotent: calling [start] while a tour is showing restarts it cleanly.
class HelpTourController {
  HelpTourController(this.steps);

  final List<HelpStep> steps;
  OverlayEntry? _entry;
  final ValueNotifier<int> _index = ValueNotifier<int>(0);
  OverlayState? _overlay;

  bool get isShowing => _entry != null;

  void start(BuildContext context) {
    if (steps.isEmpty) return;
    _remove(); // idempotent: tear down any existing overlay first
    _index.value = 0;
    _overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _HelpTourView(
        steps: steps,
        index: _index,
        onNext: _next,
        onBack: _back,
        onSkip: _remove,
      ),
    );
    _overlay!.insert(_entry!);
  }

  void _next() {
    if (_index.value >= steps.length - 1) {
      _remove();
    } else {
      _index.value++;
    }
  }

  void _back() {
    if (_index.value > 0) _index.value--;
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  /// Close the tour if it is open (e.g. a screen wants the hardware back button
  /// to dismiss the tour instead of leaving the screen).
  void dismiss() => _remove();

  /// Call from the hosting screen's dispose() so a tour left open when the user
  /// navigates away does not leak an OverlayEntry over the next screen.
  void dispose() {
    _remove();
    _index.dispose();
  }
}

class _HelpTourView extends StatefulWidget {
  const _HelpTourView({
    required this.steps,
    required this.index,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final List<HelpStep> steps;
  final ValueNotifier<int> index;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkip;

  @override
  State<_HelpTourView> createState() => _HelpTourViewState();
}

class _HelpTourViewState extends State<_HelpTourView> {
  Rect? _targetRect;
  int _preparedFor = -1;

  @override
  void initState() {
    super.initState();
    widget.index.addListener(_onStepChanged);
    _prepare();
  }

  @override
  void dispose() {
    widget.index.removeListener(_onStepChanged);
    super.dispose();
  }

  void _onStepChanged() => _prepare();

  /// Scroll the target into view (if asked), then measure it after a frame.
  Future<void> _prepare() async {
    final i = widget.index.value;
    _preparedFor = i;
    // Clear the previous step's cutout while preparing the next. Guarded so the
    // first call (from initState, which runs inside the Overlay's build) does
    // not call setState during build — on that first pass the rect is already
    // null, so there is nothing to clear.
    if (_targetRect != null) setState(() => _targetRect = null);

    final step = widget.steps[i];
    if (step.ensureVisible != null) {
      try {
        await step.ensureVisible!();
      } catch (_) {}
      // Bail if the step advanced while we were awaiting.
      if (!mounted || _preparedFor != i) return;
    }

    // Auto-scroll the target to the middle of its scrollable (if any) so it is
    // never clipped by a screen edge, app bar, or bottom nav bar. No-op when
    // the target is not inside a Scrollable.
    final ctx = step.targetKey?.currentContext;
    if (ctx != null && ctx.mounted) {
      try {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } catch (_) {}
      if (!mounted || _preparedFor != i) return;
    }

    // Measure on the next frame so any scroll/layout has settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _preparedFor != i) return;
      setState(() => _targetRect = _measure(step.targetKey));
    });
  }

  Rect? _measure(GlobalKey? key) {
    if (key == null) return null;
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final obj = ctx.findRenderObject();
    if (obj is! RenderBox || !obj.attached || !obj.hasSize) return null;
    final topLeft = obj.localToGlobal(Offset.zero);
    return topLeft & obj.size;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ValueListenableBuilder<int>(
      valueListenable: widget.index,
      builder: (context, i, _) {
        final step = widget.steps[i];
        final total = widget.steps.length;
        final rect = _targetRect;
        // Inflate the cutout a touch so it doesn't clip the widget's edge.
        final hole = rect?.inflate(6);

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) widget.onSkip();
          },
          child: Stack(
            children: [
              // Scrim + cutout. Tapping the dim area does nothing (absorbed).
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {}, // swallow taps so underlying screen is inert
                  child: CustomPaint(
                    painter: _ScrimPainter(hole: hole, circle: step.circle),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              _card(context, step, i, total, hole, isDark),
            ],
          ),
        );
      },
    );
  }

  Widget _card(BuildContext context, HelpStep step, int i, int total, Rect? hole,
      bool isDark) {
    final media = MediaQuery.of(context);
    final safe = media.padding;
    final screen = media.size;
    const cardMaxWidth = 340.0;
    const margin = 20.0;

    final cardColor = isDark ? kPanelDark : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final bodyColor = isDark ? Colors.white70 : const Color(0xFF444444);

    final cardMaterial = Material(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: kAccentInk.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${i + 1} / $total',
                      style: TextStyle(
                        color: kAccentInk,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  InkResponse(
                    onTap: widget.onSkip,
                    radius: 20,
                    child: Icon(Icons.close,
                        size: 20,
                        color: isDark ? Colors.white54 : Colors.black45),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  step.title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in step.body)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: kAccentInk.withValues(alpha: 0.7),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                line,
                                style: TextStyle(
                                  color: bodyColor,
                                  fontSize: 13.5,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (i > 0)
                    TextButton(
                      onPressed: widget.onBack,
                      child: Text('Back',
                          style: TextStyle(
                              color: isDark ? Colors.white60 : Colors.black54)),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: widget.onNext,
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentInk,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(i == total - 1 ? 'Done' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

    // Wraps the card so it never exceeds [maxHeight]: SingleChildScrollView
    // with a loose (non-tight) height constraint sizes itself to the child by
    // default, so this is a no-op when content is shorter; when content is
    // taller than maxHeight, it's clamped there and scrolls internally — the
    // card always stays fully on screen no matter how little room the chosen
    // side has.
    Widget bounded(double maxHeight) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: cardMaxWidth, maxHeight: maxHeight),
          child: SingleChildScrollView(child: cardMaterial),
        );

    // Vertical placement: prefer the side of the cutout with more room. With no
    // cutout, center the card within the full safe-area height.
    if (hole == null) {
      final maxH = screen.height - safe.top - safe.bottom - margin * 2;
      return Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: margin),
          child: bounded(maxH),
        ),
      );
    }

    const gap = 16.0;
    final spaceBelow = screen.height - hole.bottom - safe.bottom - gap - margin;
    final spaceAbove = hole.top - safe.top - gap - margin;
    final below = spaceBelow >= spaceAbove;
    // Safety floor so a near-zero available side never yields a degenerate
    // (or negative) height constraint — the card still stays on screen and
    // scrolls internally, just tightly.
    final maxH = math.max(below ? spaceBelow : spaceAbove, 100.0);

    return Positioned(
      left: margin,
      right: margin,
      top: below ? hole.bottom + gap : null,
      bottom: below ? null : screen.height - hole.top + gap,
      child: Align(
        alignment: Alignment.topCenter,
        child: bounded(maxH),
      ),
    );
  }
}

/// Paints the dim scrim with a hole punched out over [hole].
class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({required this.hole, required this.circle});
  final Rect? hole;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.72);

    if (hole == null) {
      canvas.drawRect(bounds, scrim);
      return;
    }

    final Path holePath = Path();
    if (circle) {
      final r = hole!.longestSide / 2;
      holePath.addOval(Rect.fromCircle(center: hole!.center, radius: r));
    } else {
      holePath.addRRect(
          RRect.fromRectAndRadius(hole!, const Radius.circular(14)));
    }

    final scrimPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      holePath,
    );
    canvas.drawPath(scrimPath, scrim);

    // Subtle accent ring around the spotlight.
    canvas.drawPath(
      holePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = kAccentPale.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter old) =>
      old.hole != hole || old.circle != circle;
}

/// The "?" icon button. Drop into an AppBar's `actions` or any Row.
class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.controller, this.color});

  final HelpTourController controller;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Help',
      icon: Icon(Icons.help_outline, color: color),
      onPressed: () => controller.start(context),
    );
  }
}
