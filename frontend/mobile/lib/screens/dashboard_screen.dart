import 'dart:async';

import 'package:flutter/material.dart';

import '../content/doc_controller.dart';
import '../content/doc_service.dart';
import '../services/geofence_service.dart';
import '../services/notification_service.dart';
import 'device_test_screen.dart';
import 'doc_screen.dart';
import 'mode_selection_screen.dart';
import 'notices_screen.dart';
import 'settings_screen.dart';

/// Home screen (Figma node 7:269, "4.1.1 SUAR Dashboard"). Only the
/// Emergency Mode card is wired; the rest is static chrome for now.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final GlobalKey<_PrepSummaryCardState> _prepKey = GlobalKey();
  final _geofence = GeofenceService();
  Timer? _geofenceTimer;

  @override
  void initState() {
    super.initState();
    // Danger-zone proximity check on open + periodically while in foreground.
    _geofence.check();
    _geofenceTimer = Timer.periodic(const Duration(seconds: 60), (_) => _geofence.check());
  }

  @override
  void dispose() {
    _geofenceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Reference height is roughly this content's natural size on the
            // Figma frame (800px tall). Larger screens scale fixed-height
            // elements up a little to fill space instead of leaving a gap;
            // smaller screens scale down before falling back to scrolling.
            final scale = (constraints.maxHeight / 800).clamp(0.85, 1.2);
            return RefreshIndicator(
              onRefresh: () async { await _prepKey.currentState?.reload(); },
              child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: 21,
                vertical: 16 * scale,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        // Bottom-align the wordmark with the flame's base.
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Flame mark (height-constrained so the aspect ratio
                          // is preserved). Black for this light header.
                          Image.asset(
                            'assets/logo/suar_logo_black.png',
                            height: 30,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'SUAR',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _NoticesBell(),
                          IconButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            ),
                            icon: const Icon(
                              Icons.settings_outlined,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(height: 24 * scale),
                  const _NoticesBanner(),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ModeSelectionScreen(),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 121 * scale,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAACAC),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 40,
                            color: Colors.black,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Emergency Mode',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  _PrepSummaryCard(key: _prepKey),
                  SizedBox(height: 16 * scale),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DeviceTestScreen(),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 153 * scale,
                      decoration: BoxDecoration(
                        color: const Color(0xFFA7C7E7),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.science_outlined,
                            size: 40,
                            color: Colors.black,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Device Test',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 24,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  const _TipsCard(),
                ],
              ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.black12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: const [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home_rounded, color: Colors.black54),
                  Text(
                    'Dashboard',
                    style: TextStyle(color: Colors.black54, fontSize: 14),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.medical_services_outlined, color: Colors.black),
                  Text(
                    'Medical Information',
                    style: TextStyle(color: Colors.black, fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live "Prepare for the worst" card: real overall % + the next few incomplete
/// items, pulled from the cached prep plan. Reloads on return from the tracker.
class _PrepSummaryCard extends StatefulWidget {
  const _PrepSummaryCard({super.key});

  @override
  State<_PrepSummaryCard> createState() => _PrepSummaryCardState();
}

class _PrepSummaryCardState extends State<_PrepSummaryCard> with WidgetsBindingObserver {
  final _service = DocService();
  late final DocController _ctrl = DocController(_service.repo);
  bool _loading = true;
  bool _hasPlan = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  // Auto-refresh the prepared % when the app returns to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Pull-to-refresh hook for the dashboard.
  Future<void> reload() => _load();

  Future<void> _load() async {
    final docs = await _service.loadDocs('prep');
    if (docs.isNotEmpty) {
      await _ctrl.load(docs.first);
      _hasPlan = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openTracker() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const DocScreen(category: 'prep', title: 'Disaster Preparation'),
      ),
    );
    // Fill-state may have changed — refresh progress + the %.
    if (_hasPlan && _ctrl.doc != null && mounted) {
      await _ctrl.load(_ctrl.doc!);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = _hasPlan ? _ctrl.overallPercent : 0.0;
    final groups = _hasPlan ? _ctrl.incompleteGroups : const <MapEntry<String, List<String>>>[];
    final shownCount = groups.fold<int>(0, (a, g) => a + g.value.length);
    final moreCount = _hasPlan ? (_ctrl.incompleteTotal - shownCount) : 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: _loading
          ? const SizedBox(
              height: 60,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hasPlan && _ctrl.doc != null
                      ? _ctrl.doc!.percentText.replaceAll('{p}', pct.round().toString())
                      : 'Set up your emergency preparedness:',
                  style: const TextStyle(color: Colors.black, fontSize: 12),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 11,
                    backgroundColor: Colors.black12,
                    color: const Color(0xFF62E24B),
                  ),
                ),
                if (groups.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'To be improved:',
                    style: TextStyle(
                        color: Colors.black, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  for (final g in groups)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(g.key,
                              style: const TextStyle(
                                  color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
                          for (final item in g.value)
                            Padding(
                              padding: const EdgeInsets.only(left: 8, top: 1),
                              child: Text('- $item',
                                  style: const TextStyle(color: Colors.black87, fontSize: 12, height: 1.4)),
                            ),
                        ],
                      ),
                    ),
                  if (moreCount > 0)
                    Text('…and $moreCount more',
                        style: const TextStyle(color: Colors.black54, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                Center(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _openTracker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFA7C7E7),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Go Improve',
                        style: TextStyle(
                            color: Colors.black, fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Bell icon in the dashboard header. Red dot when any active notice is unseen.
/// Tapping opens the Notices list (which marks them seen).
class _NoticesBell extends StatefulWidget {
  const _NoticesBell();

  @override
  State<_NoticesBell> createState() => _NoticesBellState();
}

class _NoticesBellState extends State<_NoticesBell> {
  final _service = DocService();
  bool _unseen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notices = await _service.loadNotices();
    final seen = await _service.seenNoticeIds();
    final unseen = notices.any((n) => !seen.contains((n['noticeid'] ?? '').toString()));
    if (mounted) setState(() => _unseen = unseen);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NoticesScreen()));
        _load();
      },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_none_rounded, color: Colors.black),
          if (_unseen)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: const Color(0xFFD64545),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Advisory / warning / critical notices as solid banners atop the dashboard
/// (info shows only as the bell dot). Tapping opens the full announcement.
/// A critical notice auto-opens its detail once, on app open.
class _NoticesBanner extends StatefulWidget {
  const _NoticesBanner();

  @override
  State<_NoticesBanner> createState() => _NoticesBannerState();
}

class _NoticesBannerState extends State<_NoticesBanner> {
  final _service = DocService();
  List<Map<String, dynamic>> _banners = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _service.loadNotices();
    final seen = await _service.seenNoticeIds();
    // Banners for advisory/warning/critical that haven't been seen/dismissed yet.
    final banners = all
        .where((n) =>
            const ['advisory', 'warning', 'critical'].contains((n['severity'] ?? '').toString()) &&
            !seen.contains((n['noticeid'] ?? '').toString()))
        .toList();
    if (mounted) setState(() => _banners = banners);

    // OS notification for warning/critical, once each.
    final notified = await _service.notifiedNoticeIds();
    final toNotify = all.where((n) =>
        const ['warning', 'critical'].contains((n['severity'] ?? '').toString()) &&
        !notified.contains((n['noticeid'] ?? '').toString())).toList();
    for (final n in toNotify) {
      await NotificationService.instance.show(
        (n['title'] ?? '').toString(),
        (n['subtitle'] ?? '').toString(),
        high: true,
      );
    }
    if (toNotify.isNotEmpty) {
      await _service.markNoticesNotified(toNotify.map((n) => (n['noticeid'] ?? '').toString()));
    }

    // Critical auto-opens its full page once (newest unseen critical).
    Map<String, dynamic>? crit;
    for (final n in all) {
      if ((n['severity'] ?? '') == 'critical' && !seen.contains((n['noticeid'] ?? '').toString())) {
        crit = n;
        break;
      }
    }
    if (crit != null && mounted) {
      await _service.markNoticesSeen([(crit['noticeid'] ?? '').toString()]);
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoticeDetailScreen(notice: crit!)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_banners.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final n in _banners)
          _banner(context, n),
        const SizedBox(height: 6),
      ],
    );
  }

  // Pastel fills reusing the app palette (emergency pink / card blue / soft amber).
  Color _pastel(String sev) {
    switch (sev) {
      case 'critical':
        return const Color(0xFFEAACAC); // emergency-mode pink
      case 'warning':
        return const Color(0xFFF2D49B); // soft amber
      case 'advisory':
        return const Color(0xFFA7C7E7); // card blue
      default:
        return const Color(0xFFE0E0E0);
    }
  }

  Widget _banner(BuildContext context, Map<String, dynamic> n) {
    final sev = (n['severity'] ?? 'info').toString();
    final subtitle = (n['subtitle'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () async {
          await _service.markNoticesSeen([(n['noticeid'] ?? '').toString()]);
          if (context.mounted) {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoticeDetailScreen(notice: n)));
          }
          _load(); // banner disappears once seen
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: _pastel(sev), borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              const Icon(Icons.campaign_rounded, size: 18, color: Colors.black87),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((n['title'] ?? '').toString(),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black)),
                    if (subtitle.isNotEmpty)
                      Text(subtitle,
                          style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.3)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.black45, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Survival / First Aid entry rows — each opens its category guide list.
class _TipsCard extends StatelessWidget {
  const _TipsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        children: [
          _row(context, 'Survival Tips', 'survival'),
          const Divider(height: 1, color: Colors.black26, indent: 22, endIndent: 22),
          _row(context, 'First Aid Tips', 'first_aid'),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String category) => InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DocScreen(category: category, title: label),
        )),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.black, fontSize: 16)),
              ),
              const Icon(Icons.chevron_right, color: Colors.black54, size: 20),
            ],
          ),
        ),
      );
}
