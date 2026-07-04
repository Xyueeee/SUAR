import 'dart:io';

import 'package:flutter/material.dart';

import '../onboarding.dart';
import '../permissions.dart';
import '../services/app_lock.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import '../widgets/option_card.dart';
import 'dashboard_screen.dart';
import 'region_download_screen.dart';

/// Best-effort internet check (no connectivity plugin, same "just try it"
/// philosophy as [SyncService]) — gates whether the offline-map onboarding
/// page appears at all, since drawing a download box is pointless offline.
Future<bool> _hasInternetAccess() async {
  try {
    final result =
        await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 4));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// First-launch walkthrough: welcome, permissions, appearance, security
/// preferences, an optional offline-map download (only shown while online), a
/// help-button tip, then hands off to the Dashboard (which auto-opens its
/// own help tour once, via [consumeShowDashboardTourOnce]).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  final ValueNotifier<int> _page = ValueNotifier(0);

  // Null while the connectivity check is still in flight.
  bool? _online;
  late List<Widget> _pages;
  late List<bool> _canProceed;

  int get _pageCount => _pages.length;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
  }

  Future<void> _checkConnectivity() async {
    final online = await _hasInternetAccess();
    if (!mounted) return;
    setState(() {
      _online = online;
      _buildPages(online);
    });
  }

  void _buildPages(bool showMap) {
    _pages = [
      const _WelcomePage(),
      _PermissionsPage(onCanProceedChanged: (v) => _setCanProceed(1, v)),
      _AppearancePage(onCanProceedChanged: (v) => _setCanProceed(2, v)),
      _SecurityPage(onCanProceedChanged: (v) => _setCanProceed(3, v)),
      if (showMap) _OfflineMapPage(onDownloaded: _next),
      const _TipPage(),
      const _AllSetPage(),
    ];
    // Pages with scrollable content the user must see in full (including any
    // action button at the bottom) before Next unlocks. The map page is
    // optional (download-or-skip), so it's never gated.
    const gatedPages = {1, 2, 3};
    _canProceed = List<bool>.generate(_pages.length, (i) => !gatedPages.contains(i));
  }

  @override
  void dispose() {
    _controller.dispose();
    _page.dispose();
    super.dispose();
  }

  void _setCanProceed(int page, bool value) {
    if (_canProceed[page] == value) return;
    setState(() => _canProceed[page] = value);
  }

  void _next() {
    if (_page.value == _pageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _back() {
    _controller.previousPage(
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Future<void> _finish() async {
    await completeOnboarding();
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => const DashboardScreen()));
  }

  @override
  Widget build(BuildContext context) {
    if (_online == null) {
      // Brief connectivity check before the first page paints — keeps the
      // page list (and its indices) fixed for the rest of the flow instead
      // of inserting/removing the map page out from under the user mid-swipe.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: _page,
                builder: (context, i, _) => PageView(
                  controller: _controller,
                  // Swiping past a gated page (scroll-to-bottom not yet done)
                  // was bypassing the same gate the Next button enforces —
                  // Back/Next still work either way since those call the
                  // controller directly, not through gesture physics.
                  physics: _canProceed[i]
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => _page.value = i,
                  children: _pages,
                ),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: _page,
              builder: (context, i, _) => _NavBar(
                page: i,
                total: _pageCount,
                canProceed: _canProceed[i],
                onBack: _back,
                onNext: _next,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.page,
    required this.total,
    required this.canProceed,
    required this.onBack,
    required this.onNext,
  });

  final int page;
  final int total;
  final bool canProceed;
  final VoidCallback onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLast = page == total - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!canProceed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.keyboard_double_arrow_down,
                        size: 14, color: cs.onSurface.withValues(alpha: 0.45)),
                    const SizedBox(width: 4),
                    Text(
                      'Scroll down to continue',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurface.withValues(alpha: 0.45)),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                // Equal-flex sides keep the dots visually centered no matter
                // how wide "Back" or "Get Started" end up (long label, small
                // screen, larger text scale) — a fixed-width box + Spacer pair
                // skews center when the two sides aren't the same width.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: page > 0
                        ? TextButton(onPressed: onBack, child: const Text('Back'))
                        : const SizedBox.shrink(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < total; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == page ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: i == page
                                ? kAccentInk
                                : kAccentInk.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: canProceed ? onNext : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: kAccentInk,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: cs.onSurface.withValues(alpha: 0.12),
                        disabledForegroundColor: cs.onSurface.withValues(alpha: 0.38),
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      // textAlign: center matters if this ever wraps to two
                      // lines (narrow screen, large accessibility text scale)
                      // — a wrapped Text defaults each line to left
                      // TextAlign.start, which looks left-aligned even though
                      // the button itself is centered fine. Allowing wrap
                      // (instead of forcing one line) avoids clipping "Get
                      // Started" on very narrow screens.
                      child: Text(isLast ? 'Get Started' : 'Next',
                          textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Welcome page ─────────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // LayoutBuilder + minHeight lets this stay vertically centered on normal
    // screens but scroll instead of overflowing on very short screens or
    // with large accessibility text scaling.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('assets/logo/suar_logo_red.png', height: 120),
              const SizedBox(height: 28),
              Text(
                'Welcome to SUAR',
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold, color: cs.onSurface),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Offline disaster response, wherever you are. '
                'No signal, no internet, no problem.',
                style: TextStyle(
                    fontSize: 15, color: cs.onSurface.withValues(alpha: 0.65)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a page's scrollable content and reports whether the user has
/// scrolled it to the bottom — or it already fits without scrolling — so
/// onboarding's Next button can stay disabled until they've seen it all
/// (including any action button sitting at the bottom, e.g. Grant Permissions).
class _GatedScrollPage extends StatefulWidget {
  const _GatedScrollPage({
    required this.onCanProceedChanged,
    required this.padding,
    required this.children,
  });

  final ValueChanged<bool> onCanProceedChanged;
  final EdgeInsets padding;
  final List<Widget> children;

  @override
  State<_GatedScrollPage> createState() => _GatedScrollPageState();
}

class _GatedScrollPageState extends State<_GatedScrollPage> {
  final _controller = ScrollController();
  bool? _reported;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(covariant _GatedScrollPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Content (children) may have grown or shrunk — e.g. Grant Permissions
    // appending a status line at the bottom — so re-check after the new
    // layout settles instead of trusting the last-known scroll position.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final atBottom = pos.maxScrollExtent <= 0 || pos.pixels >= pos.maxScrollExtent - 8;
    if (_reported != atBottom) {
      _reported = atBottom;
      widget.onCanProceedChanged(atBottom);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: _controller,
      padding: widget.padding,
      children: widget.children,
    );
  }
}

// ─── Permissions page ─────────────────────────────────────────────────────────

class _PermissionsPage extends StatefulWidget {
  const _PermissionsPage({required this.onCanProceedChanged});

  final ValueChanged<bool> onCanProceedChanged;

  @override
  State<_PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<_PermissionsPage> {
  bool _requested = false;
  bool _requesting = false;
  ({bool bluetooth, bool nearbyWifi, bool location}) _mesh =
      (bluetooth: false, nearbyWifi: false, location: false);
  bool _micGranted = false;
  bool _notifGranted = false;

  Future<void> _grant() async {
    setState(() => _requesting = true);
    await requestMeshPermissions();
    await requestLocationPermission();
    final mic = await requestMicPermission();
    final notif = await NotificationService.instance.requestPermission();
    final mesh = await meshPermissionStatuses();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _requested = true;
      _mesh = mesh;
      _micGranted = mic;
      _notifGranted = notif;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allGranted = _mesh.bluetooth &&
        _mesh.nearbyWifi &&
        _mesh.location &&
        _micGranted &&
        _notifGranted;
    return _GatedScrollPage(
      onCanProceedChanged: widget.onCanProceedChanged,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        Text('Permissions SUAR needs',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: cs.onSurface)),
        const SizedBox(height: 8),
        Text(
          'These let your phone find nearby devices and warn you of danger, '
          'even fully offline.',
          style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: 24),
        const _SectionLabel('MESH NETWORKING'),
        const SizedBox(height: 10),
        _PermCard(
          icon: Icons.bluetooth_searching,
          title: 'Bluetooth',
          body: 'Discovers and links to nearby phones over BLE.',
          status: _requested
              ? (_mesh.bluetooth ? _PermStatus.granted : _PermStatus.denied)
              : _PermStatus.pending,
        ),
        const SizedBox(height: 10),
        _PermCard(
          icon: Icons.wifi_tethering,
          title: 'Nearby Wi-Fi Devices',
          body: 'Transfers distress bundles over Wi-Fi Direct.',
          status: _requested
              ? (_mesh.nearbyWifi ? _PermStatus.granted : _PermStatus.denied)
              : _PermStatus.pending,
        ),
        const SizedBox(height: 10),
        _PermCard(
          icon: Icons.location_on_outlined,
          title: 'Location',
          body: 'Required by Android for Bluetooth scanning, and to warn '
              'you when you enter a marked danger zone.',
          status: _requested
              ? (_mesh.location ? _PermStatus.granted : _PermStatus.denied)
              : _PermStatus.pending,
        ),
        const SizedBox(height: 20),
        const _SectionLabel('SENSORS'),
        const SizedBox(height: 10),
        _PermCard(
          icon: Icons.mic_none,
          title: 'Microphone (optional)',
          body: 'Estimates ambient noise for automatic triage scoring. '
              'The app still works fully if you skip this.',
          status: _requested
              ? (_micGranted ? _PermStatus.granted : _PermStatus.denied)
              : _PermStatus.pending,
        ),
        const SizedBox(height: 20),
        const _SectionLabel('ALERTS'),
        const SizedBox(height: 10),
        _PermCard(
          icon: Icons.notifications_none,
          title: 'Notifications',
          body: 'Alerts you when you enter a marked danger zone or receive an '
              'admin notice.',
          status: _requested
              ? (_notifGranted ? _PermStatus.granted : _PermStatus.denied)
              : _PermStatus.pending,
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _requesting ? null : _grant,
          style: FilledButton.styleFrom(
            backgroundColor: kAccentInk,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(_requesting
              ? 'Requesting…'
              : (_requested ? 'Grant Permissions Again' : 'Grant Permissions')),
        ),
        if (_requested) ...[
          const SizedBox(height: 10),
          Text(
            allGranted
                ? 'All set. You can continue.'
                : 'Some permissions were not granted. You can continue anyway '
                    'and SUAR will ask again later when it needs them.',
            style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.55)),
          ),
        ],
      ],
    );
  }
}

/// Small caps section label above a group of related permission cards.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: kAccentInk.withValues(alpha: 0.85),
      ),
    );
  }
}

enum _PermStatus { pending, granted, denied }

/// One permission, its own bordered card — matches the app's existing card
/// language (e.g. dashboard's prep-summary card): [Theme]-aware surface fill,
/// thin border, 12px radius, no shadow.
class _PermCard extends StatelessWidget {
  const _PermCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.status,
  });

  final IconData icon;
  final String title;
  final String body;
  final _PermStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.05),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.15)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: kAccentInk, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    ),
                    _StatusChip(status: status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(body,
                    style:
                        TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final _PermStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      _PermStatus.granted => ('Granted', const Color(0xFF2E9E3F)),
      _PermStatus.denied => ('Not granted', const Color(0xFFD64545)),
      _PermStatus.pending => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

// ─── Security page ────────────────────────────────────────────────────────────

class _SecurityPage extends StatelessWidget {
  const _SecurityPage({required this.onCanProceedChanged});

  final ValueChanged<bool> onCanProceedChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _GatedScrollPage(
      onCanProceedChanged: onCanProceedChanged,
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        Text('Extra security',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: fg)),
        const SizedBox(height: 8),
        Text(
          'Ask for your phone\'s lock (PIN, pattern, password, or biometric) '
          'before these sensitive actions.',
          style: TextStyle(fontSize: 14, color: fg.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            // A plain Container `color` here would paint over the
            // SwitchListTiles' ink layer, hiding their splashes/background
            // highlight (Flutter's "ListTile ink splashes may be invisible"
            // warning) — Material composites the fill and ink correctly.
            color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.05),
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: AppLock.requireExitVictim,
                  builder: (context, on, _) => SwitchListTile(
                    secondary: Icon(Icons.exit_to_app, color: fg),
                    title: Text('Lock exit from Victim Mode', style: TextStyle(color: fg)),
                    subtitle: Text('Confirm before leaving victim mode',
                        style: TextStyle(color: fg.withValues(alpha: 0.54))),
                    activeThumbColor: kAccentInk,
                    value: on,
                    // No confirm-to-disable gate here (unlike Settings): both
                    // toggles still default off and this is a first-time opt-in,
                    // not yet a protection worth guarding against a bystander.
                    onChanged: AppLock.setRequireExitVictim,
                  ),
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: fg.withValues(alpha: 0.12)),
                ValueListenableBuilder<bool>(
                  valueListenable: AppLock.requireMedicalEdit,
                  builder: (context, on, _) => SwitchListTile(
                    secondary: Icon(Icons.medical_information_outlined, color: fg),
                    title: Text('Lock editing Medical Info', style: TextStyle(color: fg)),
                    subtitle: Text('Confirm before editing your medical info',
                        style: TextStyle(color: fg.withValues(alpha: 0.54))),
                    activeThumbColor: kAccentInk,
                    value: on,
                    onChanged: AppLock.setRequireMedicalEdit,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Not sure? Leave these off. You can turn them on anytime later in '
          'Settings > Security.',
          style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12),
        ),
      ],
    );
  }
}

// ─── Appearance page ──────────────────────────────────────────────────────────

class _AppearancePage extends StatelessWidget {
  const _AppearancePage({required this.onCanProceedChanged});

  final ValueChanged<bool> onCanProceedChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        return _GatedScrollPage(
          onCanProceedChanged: onCanProceedChanged,
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            Text('Choose your look',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              'You can change this anytime later in Settings.',
              style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.65)),
            ),
            const SizedBox(height: 20),
            for (final opt in const [
              (ThemeMode.light, Icons.light_mode_outlined, 'Light',
                'Bright white background. Best for outdoor use in sunlight.'),
              (ThemeMode.system, Icons.brightness_auto_outlined, 'System default',
                'Follows your phone\'s display setting.'),
              (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark',
                'Deep black background. Easier on the eyes at night.'),
            ]) ...[
              OptionCard(
                icon: opt.$2,
                label: opt.$3,
                description: opt.$4,
                selected: mode == opt.$1,
                preview: ThemePreview(themeMode: opt.$1),
                onTap: () => setThemeMode(opt.$1),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

// ─── Offline map page (shown only when online) ───────────────────────────────

class _OfflineMapPage extends StatefulWidget {
  const _OfflineMapPage({required this.onDownloaded});

  final VoidCallback onDownloaded;

  @override
  State<_OfflineMapPage> createState() => _OfflineMapPageState();
}

class _OfflineMapPageState extends State<_OfflineMapPage> {
  bool _downloaded = false;

  Future<void> _openPicker() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RegionDownloadScreen()),
    );
    if (saved != true || !mounted) return;
    setState(() => _downloaded = true);
    // First successful download auto-advances — no reason to make the user
    // tap Next themselves once they've done the one thing this page asks for.
    widget.onDownloaded();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kAccentInk.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.map_outlined, size: 48, color: kAccentInk),
              ),
              const SizedBox(height: 24),
              Text('Save your area for offline',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cs.onSurface),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'You\'re online right now. Draw a box around your area to save its '
                'map for when you lose signal.',
                style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.65)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _openPicker,
                icon: const Icon(Icons.download_outlined),
                label: Text(_downloaded ? 'Download another area' : 'Choose area to download'),
                style: FilledButton.styleFrom(
                  backgroundColor: kAccentInk,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              if (_downloaded) ...[
                const SizedBox(height: 10),
                Text('Saved. You can add more later in Settings.',
                    style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.55))),
              ],
              const SizedBox(height: 8),
              Text(
                'Optional, you can skip this and download areas anytime in Settings.',
                style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Tip page ─────────────────────────────────────────────────────────────────

class _TipPage extends StatelessWidget {
  const _TipPage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: kAccentInk.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.help_outline, size: 48, color: kAccentInk),
              ),
              const SizedBox(height: 24),
              Text('Not sure what to do?',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cs.onSurface),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'Look for the ? help button on any screen. It walks you through '
                'exactly what everything does.',
                style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.65)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── All set page ─────────────────────────────────────────────────────────────

class _AllSetPage extends StatelessWidget {
  const _AllSetPage();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF2E9E3F).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle, size: 48, color: Color(0xFF2E9E3F)),
              ),
              const SizedBox(height: 24),
              Text('You\'re all set',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: cs.onSurface),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'Welcome aboard. SUAR is ready to help, online or off.',
                style: TextStyle(fontSize: 15, color: cs.onSurface.withValues(alpha: 0.65)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
