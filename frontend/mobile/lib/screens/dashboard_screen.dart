import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../content/doc_models.dart';
import '../help/help_tour.dart';
import '../onboarding.dart';
import '../services/app_lock.dart';
import '../theme.dart' show kAccentInk, kPanelDark;
import '../content/doc_service.dart';
import '../services/geofence_service.dart';
import '../services/notification_service.dart';
import 'device_test_screen.dart';
import 'doc_screen.dart';
import 'mode_selection_screen.dart';
import 'notices_screen.dart';
import 'photo_crop_screen.dart';
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
  final GlobalKey<_NoticesBellState> _noticesBellKey = GlobalKey();
  final GlobalKey<_NoticesBannerState> _noticesBannerKey = GlobalKey();
  final _geofence = GeofenceService.instance;
  Timer? _geofenceTimer;
  int _tab = 0;

  // Help tour targets
  final _kEmergency = GlobalKey();
  final _kPrep = GlobalKey();
  final _kDeviceTest = GlobalKey();
  final _kTips = GlobalKey();
  late final HelpTourController _help = HelpTourController([
    HelpStep(
      targetKey: _kEmergency,
      title: 'Emergency Mode',
      body: const [
        'Tap here if you are in an emergency right now.',
        'You choose Victim or Helper, then your phone joins the offline rescue network.',
      ],
    ),
    HelpStep(
      targetKey: _kPrep,
      title: 'Get ready before disaster',
      body: const [
        'A short checklist for preparing ahead of time.',
        'Tap it to open the full plan and track what you have done.',
      ],
    ),
    HelpStep(
      targetKey: _kDeviceTest,
      title: 'Device Test',
      body: const [
        'Run this to check Bluetooth and Wi-Fi Direct work on your phone.',
        'Best done now, before you actually need them.',
      ],
    ),
    HelpStep(
      targetKey: _kTips,
      title: 'Survival & first aid tips',
      body: const [
        'Quick reference guides, useful when you need help fast.',
        'Works offline once loaded.',
      ],
    ),
  ]);

  @override
  void initState() {
    super.initState();
    // Danger-zone proximity check on open + periodically while in foreground
    // (catches a zone newly drawn around a stationary user, which the
    // distance-filtered background stream below wouldn't notice on its own).
    _geofence.check();
    _geofenceTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _geofence.check();
      // Dashboard stays mounted indefinitely (IndexedStack), so the bell dot
      // and banner otherwise never notice a notice posted after this screen
      // first loaded — piggyback their refresh on the same periodic tick.
      _noticesBellKey.currentState?.reload();
      _noticesBannerKey.currentState?.reload();
    });
    // Keeps alerting after the user backgrounds/leaves the app — safe to
    // call every time Dashboard opens, no-ops if already running.
    _geofence.startBackgroundMonitoring();
    _maybeShowTourAfterOnboarding();
  }

  Future<void> _maybeShowTourAfterOnboarding() async {
    if (!await consumeShowDashboardTourOnce()) return;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _help.start(context);
    });
  }

  @override
  void dispose() {
    _help.dispose();
    _geofenceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          _buildDashboardTab(context),
          const _MedicalInfoContent(),
        ],
      ),
      bottomNavigationBar: Theme(
        data: Theme.of(context).copyWith(
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) => setState(() => _tab = i),
          backgroundColor: cs.surface,
          selectedItemColor: cs.onSurface,
          unselectedItemColor: cs.onSurface.withValues(alpha: 0.45),
          elevation: 1,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Dashboard',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.medical_services_outlined),
              activeIcon: Icon(Icons.medical_services),
              label: 'Medical Information',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardTab(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
          builder: (context, constraints) {
            final cs = Theme.of(context).colorScheme;
            final dark = Theme.of(context).brightness == Brightness.dark;
            // Reference height is roughly this content's natural size on the
            // Figma frame (800px tall). Larger screens scale fixed-height
            // elements up a little to fill space instead of leaving a gap;
            // smaller screens scale down before falling back to scrolling.
            final scale = (constraints.maxHeight / 800).clamp(0.85, 1.2);
            return RefreshIndicator(
              onRefresh: () async {
                await _prepKey.currentState?.reload();
                await _geofence.check();
                await _noticesBellKey.currentState?.reload();
                await _noticesBannerKey.currentState?.reload();
              },
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
                          // is preserved). Swaps to white in dark mode.
                          Image.asset(
                            dark
                                ? 'assets/logo/suar_logo_white.png'
                                : 'assets/logo/suar_logo_black.png',
                            height: 30,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'SUAR',
                            style: TextStyle(
                              color: cs.onSurface,
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
                          HelpButton(controller: _help, color: cs.onSurface),
                          _NoticesBell(key: _noticesBellKey),
                          IconButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            ),
                            icon: Icon(
                              Icons.settings_outlined,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(height: 24 * scale),
                  const _DangerZoneCard(),
                  _NoticesBanner(key: _noticesBannerKey),
                  InkWell(
                    key: _kEmergency,
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
                  KeyedSubtree(key: _kPrep, child: _PrepSummaryCard(key: _prepKey)),
                  SizedBox(height: 16 * scale),
                  InkWell(
                    key: _kDeviceTest,
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DeviceTestScreen(),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 121 * scale,
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
                  _TipsCard(key: _kTips),
                ],
              ),
              ),
            );
          },
        ),
      );
  }
}

// ─── Medical Information tab ─────────────────────────────────────────────────

const _kMedName = 'medical_name';
const _kMedGender = 'medical_gender';
const _kMedAge = 'medical_age';
const _kMedBloodType = 'medical_blood_type';
const _kMedDnr = 'medical_dnr';
const _kMedAllergyDrug = 'medical_allergy_drug';
const _kMedAllergyFood = 'medical_allergy_food';
const _kMedAllergyInsect = 'medical_allergy_insect';
const _kMedAllergyLatex = 'medical_allergy_latex';
const _kMedNotes = 'medical_notes';
const _kMedPhotoPath = 'medical_photo_path';

class _MedicalInfoContent extends StatefulWidget {
  const _MedicalInfoContent();

  @override
  State<_MedicalInfoContent> createState() => _MedicalInfoContentState();
}

class _MedicalInfoContentState extends State<_MedicalInfoContent> {
  Map<String, String> _data = {};
  String _deviceId = '';
  bool _loading = true;
  bool _disposed = false;

  // Help tour targets
  final _kAvatar = GlobalKey();
  final _kAllergies = GlobalKey();
  final _kPrivacy = GlobalKey();
  late final HelpTourController _help = HelpTourController([
    HelpStep(
      targetKey: _kAvatar,
      title: 'This is only on your phone',
      body: const [
        'Your medical details never leave this device.',
        'They are not sent over Bluetooth, Wi-Fi Direct, or to the cloud.',
      ],
    ),
    HelpStep(
      targetKey: _kAllergies,
      title: 'Why fill this in',
      body: const [
        'If you are unconscious, a helper holding your unlocked phone can read this to treat you correctly.',
        'Allergies, blood type, and DNR status are the details rescuers need most.',
      ],
    ),
    HelpStep(
      targetKey: _kPrivacy,
      title: 'Keep it current',
      body: const [
        'This is the one thing in the app that is personal to you, so keep it up to date.',
        'Tap Edit at the top to change anything.',
      ],
    ),
  ]);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _help.dispose();
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || !mounted) return;
    setState(() {
      _deviceId = prefs.getString(deviceIdPrefKey) ?? '';
      _data = {
        _kMedName: prefs.getString(_kMedName) ?? '',
        _kMedGender: prefs.getString(_kMedGender) ?? '',
        _kMedAge: prefs.getString(_kMedAge) ?? '',
        _kMedBloodType: prefs.getString(_kMedBloodType) ?? '',
        _kMedDnr: prefs.getString(_kMedDnr) ?? 'false',
        _kMedAllergyDrug: prefs.getString(_kMedAllergyDrug) ?? '',
        _kMedAllergyFood: prefs.getString(_kMedAllergyFood) ?? '',
        _kMedAllergyInsect: prefs.getString(_kMedAllergyInsect) ?? '',
        _kMedAllergyLatex: prefs.getString(_kMedAllergyLatex) ?? '',
        _kMedNotes: prefs.getString(_kMedNotes) ?? '',
        _kMedPhotoPath: prefs.getString(_kMedPhotoPath) ?? '',
      };
      _loading = false;
    });
  }

  String _display(String key, {String fallback = '—'}) {
    final v = _data[key] ?? '';
    return v.isEmpty ? fallback : v;
  }

  String get _nameFallback => _deviceId.isEmpty
      ? '—'
      : 'SUAR-${deviceNameSuffix(_deviceId)}';

  String? get _photoPath {
    final p = _data[_kMedPhotoPath] ?? '';
    if (p.isEmpty) return null;
    final f = File(p);
    return f.existsSync() ? p : null;
  }

  String get _initials {
    final n = (_data[_kMedName] ?? '').trim();
    if (n.isEmpty) return '';
    final parts = n.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return parts.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      bottom: false,
      child: _loading
          ? Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurface.withValues(alpha: 0.26)))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(21, 16, 21, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Image.asset(
                              dark
                                  ? 'assets/logo/suar_logo_white.png'
                                  : 'assets/logo/suar_logo_black.png',
                              height: 30),
                          const SizedBox(width: 8),
                          Text(
                            'SUAR',
                            style: TextStyle(
                              color: cs.onSurface,
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
                          HelpButton(controller: _help, color: cs.onSurface),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () async {
                              final navigator = Navigator.of(context);
                              if (AppLock.requireMedicalEdit.value) {
                                final ok = await AppLock.authenticate(
                                    'Confirm to edit medical info');
                                if (!ok) return;
                              }
                              await navigator.push(
                                MaterialPageRoute(
                                  builder: (_) => _MedInfoEditScreen(initial: _data),
                                ),
                              );
                              _load();
                            },
                            child: const Text(
                              'Edit',
                              style: TextStyle(color: Color(0xFF3E6FA8), fontSize: 15),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Center(
                    key: _kAvatar,
                    child: Column(
                      children: [
                        () {
                          final photo = _photoPath;
                          final initials = _initials;
                          if (photo != null) {
                            return CircleAvatar(
                              radius: 48,
                              backgroundImage: FileImage(File(photo)),
                            );
                          }
                          if (initials.isNotEmpty) {
                            return CircleAvatar(
                              radius: 48,
                              backgroundColor: cs.onSurface.withValues(alpha: 0.85),
                              child: Text(
                                initials,
                                style: TextStyle(
                                  color: cs.surface,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            );
                          }
                          return CircleAvatar(
                            radius: 48,
                            backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                            child: Icon(Icons.person_rounded, size: 52, color: cs.onSurface.withValues(alpha: 0.38)),
                          );
                        }(),
                        const SizedBox(height: 12),
                        Text(
                          _display(_kMedName, fallback: _nameFallback),
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _MedCard(
                    title: 'Basic Information',
                    children: [
                      _MedField('Gender', _display(_kMedGender)),
                      _MedField('Age', _display(_kMedAge)),
                      _MedField('Blood Type', _display(_kMedBloodType)),
                      _MedField(
                        'DNR Status',
                        _data[_kMedDnr] == 'true' ? 'Do Not Resuscitate' : 'No DNR',
                        last: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _MedCard(
                    key: _kAllergies,
                    title: 'Allergies',
                    children: [
                      _MedField('Drug', _display(_kMedAllergyDrug)),
                      _MedField('Food', _display(_kMedAllergyFood)),
                      _MedField('Insect', _display(_kMedAllergyInsect)),
                      _MedField('Latex', _display(_kMedAllergyLatex), last: true),
                    ],
                  ),
                  ...[
                    const SizedBox(height: 16),
                    _MedCard(
                      title: 'Additional Notes',
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: Text(
                              (_data[_kMedNotes] ?? '').isEmpty ? 'None' : _data[_kMedNotes]!,
                              style: TextStyle(
                                fontSize: 15,
                                color: cs.onSurface.withValues(alpha: 0.87),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Center(
                    key: _kPrivacy,
                    child: Text(
                      'This information is stored locally on your device only\nand is never transmitted.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _MedCard extends StatelessWidget {
  const _MedCard({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.54),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _MedField extends StatelessWidget {
  const _MedField(this.label, this.value, {this.last = false});
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.54))),
              const SizedBox(width: 16),
              // Expanded + wrap so a long value grows the box's height instead
              // of overflowing the row horizontally.
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 15, color: cs.onSurface, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        if (!last)
          Divider(height: 1, indent: 16, endIndent: 16, color: cs.onSurface.withValues(alpha: 0.12)),
      ],
    );
  }
}

/// Read-only body of the medical info screen — same data as [_MedicalInfoContent]
/// but with no header row or edit button; used inside [MedicalInfoScreen].
class _MedicalInfoBody extends StatefulWidget {
  const _MedicalInfoBody();

  @override
  State<_MedicalInfoBody> createState() => _MedicalInfoBodyState();
}

class _MedicalInfoBodyState extends State<_MedicalInfoBody> {
  Map<String, String> _data = {};
  String _deviceId = '';
  bool _loading = true;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || !mounted) return;
    setState(() {
      _deviceId = prefs.getString(deviceIdPrefKey) ?? '';
      _data = {
        _kMedName: prefs.getString(_kMedName) ?? '',
        _kMedGender: prefs.getString(_kMedGender) ?? '',
        _kMedAge: prefs.getString(_kMedAge) ?? '',
        _kMedBloodType: prefs.getString(_kMedBloodType) ?? '',
        _kMedDnr: prefs.getString(_kMedDnr) ?? 'false',
        _kMedAllergyDrug: prefs.getString(_kMedAllergyDrug) ?? '',
        _kMedAllergyFood: prefs.getString(_kMedAllergyFood) ?? '',
        _kMedAllergyInsect: prefs.getString(_kMedAllergyInsect) ?? '',
        _kMedAllergyLatex: prefs.getString(_kMedAllergyLatex) ?? '',
        _kMedNotes: prefs.getString(_kMedNotes) ?? '',
        _kMedPhotoPath: prefs.getString(_kMedPhotoPath) ?? '',
      };
      _loading = false;
    });
  }

  String _display(String key, {String fallback = '—'}) {
    final v = _data[key] ?? '';
    return v.isEmpty ? fallback : v;
  }

  String get _nameFallback => _deviceId.isEmpty
      ? '—'
      : 'SUAR-${deviceNameSuffix(_deviceId)}';

  String? get _photoPath {
    final p = _data[_kMedPhotoPath] ?? '';
    if (p.isEmpty) return null;
    final f = File(p);
    return f.existsSync() ? p : null;
  }

  String get _initials {
    final n = (_data[_kMedName] ?? '').trim();
    if (n.isEmpty) return '';
    final parts = n.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return parts.first[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurface.withValues(alpha: 0.26)));
    }
    final initials = _initials;
    final photo = _photoPath;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(21, 16, 21, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                photo != null
                    ? CircleAvatar(radius: 48, backgroundImage: FileImage(File(photo)))
                    : initials.isNotEmpty
                        ? CircleAvatar(
                            radius: 48,
                            backgroundColor: cs.onSurface.withValues(alpha: 0.85),
                            child: Text(initials,
                                style: TextStyle(
                                    color: cs.surface, fontSize: 30, fontWeight: FontWeight.bold)),
                          )
                        : CircleAvatar(
                            radius: 48,
                            backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                            child: Icon(Icons.person_rounded,
                                size: 52, color: cs.onSurface.withValues(alpha: 0.38)),
                          ),
                const SizedBox(height: 12),
                Text(_display(_kMedName, fallback: _nameFallback),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _MedCard(title: 'Basic Information', children: [
            _MedField('Gender', _display(_kMedGender)),
            _MedField('Age', _display(_kMedAge)),
            _MedField('Blood Type', _display(_kMedBloodType)),
            _MedField('DNR Status',
                _data[_kMedDnr] == 'true' ? 'Do Not Resuscitate' : 'No DNR', last: true),
          ]),
          const SizedBox(height: 16),
          _MedCard(title: 'Allergies', children: [
            _MedField('Drug', _display(_kMedAllergyDrug)),
            _MedField('Food', _display(_kMedAllergyFood)),
            _MedField('Insect', _display(_kMedAllergyInsect)),
            _MedField('Latex', _display(_kMedAllergyLatex), last: true),
          ]),
          ...[
            const SizedBox(height: 16),
            _MedCard(title: 'Additional Notes', children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    (_data[_kMedNotes] ?? '').isEmpty ? 'None' : _data[_kMedNotes]!,
                    style: TextStyle(fontSize: 15, color: cs.onSurface.withValues(alpha: 0.87)),
                  ),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 24),
          Center(
            child: Text(
              'This information is stored locally on your device only\nand is never transmitted.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Standalone read-only medical info screen — same data as the dashboard tab
/// but with an AppBar for back navigation and no edit capability.
/// When [VictimRadioStatus] is in the active theme (injected by victim mode),
/// [RadioPill] in the AppBar shows the live radio status.
class MedicalInfoScreen extends StatelessWidget {
  const MedicalInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text('Medical Information'),
        actions: const [RadioPill()],
      ),
      body: const _MedicalInfoBody(),
    );
  }
}

// ─── Medical Information edit screen ─────────────────────────────────────────

class _MedInfoEditScreen extends StatefulWidget {
  const _MedInfoEditScreen({required this.initial});
  final Map<String, String> initial;

  @override
  State<_MedInfoEditScreen> createState() => _MedInfoEditScreenState();
}

class _MedInfoEditScreenState extends State<_MedInfoEditScreen> {
  late Map<String, String> _vals;
  late TextEditingController _noteCtrl;
  late TextEditingController _allergyDrugCtrl;
  late TextEditingController _allergyFoodCtrl;
  late TextEditingController _allergyInsectCtrl;
  late TextEditingController _allergyLatexCtrl;
  final _picker = ImagePicker();

  static const _genders = ['Male', 'Female', 'Other', 'Prefer not to say'];
  static const _bloodTypes = ['A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−', 'Unknown'];

  @override
  void initState() {
    super.initState();
    _vals = Map.from(widget.initial);
    _vals.putIfAbsent(_kMedNotes, () => '');
    _vals.putIfAbsent(_kMedPhotoPath, () => '');
    _vals.putIfAbsent(_kMedAllergyDrug, () => '');
    _vals.putIfAbsent(_kMedAllergyFood, () => '');
    _vals.putIfAbsent(_kMedAllergyInsect, () => '');
    _vals.putIfAbsent(_kMedAllergyLatex, () => '');
    _noteCtrl = TextEditingController(text: _vals[_kMedNotes] ?? '');
    _allergyDrugCtrl = TextEditingController(text: _vals[_kMedAllergyDrug] ?? '');
    _allergyFoodCtrl = TextEditingController(text: _vals[_kMedAllergyFood] ?? '');
    _allergyInsectCtrl = TextEditingController(text: _vals[_kMedAllergyInsect] ?? '');
    _allergyLatexCtrl = TextEditingController(text: _vals[_kMedAllergyLatex] ?? '');
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    _noteCtrl.dispose();
    _allergyDrugCtrl.dispose();
    _allergyFoodCtrl.dispose();
    _allergyInsectCtrl.dispose();
    _allergyLatexCtrl.dispose();
    super.dispose();
  }

  Future<void> _commit(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    if (mounted) setState(() => _vals[key] = value);
  }

  String _val(String key) => _vals[key] ?? '';

  ColorScheme get _cs => Theme.of(context).colorScheme;

  Future<void> _editText(String key, String label, {
    TextInputType keyboard = TextInputType.text,
    TextCapitalization cap = TextCapitalization.sentences,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        label: label,
        initial: _val(key),
        keyboard: keyboard,
        cap: cap,
      ),
    );
    if (result != null) await _commit(key, result);
  }

  Future<void> _pickOption(String key, String label, List<String> options) async {
    String selected = _val(key);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text(label),
          content: SingleChildScrollView(
            child: RadioGroup<String>(
              groupValue: selected,
              onChanged: (v) { if (v != null) setDlgState(() => selected = v); },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: options.map((o) => RadioListTile<String>(
                  value: o,
                  title: Text(o),
                )).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: const Text('Save', style: TextStyle(color: Color(0xFF3E6FA8))),
            ),
          ],
        ),
      ),
    );
    if (result != null) await _commit(key, result);
  }

  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;
    if (!mounted) return;
    final croppedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => PhotoCropScreen(imagePath: picked.path)),
    );
    if (croppedPath == null) return;
    await _commit(_kMedPhotoPath, croppedPath);
  }

  Future<void> _removePhoto() async {
    await _commit(_kMedPhotoPath, '');
  }

  Widget _divider() => Divider(color: _cs.onSurface.withValues(alpha: 0.12), height: 1, indent: 16, endIndent: 16);

  Widget _allergyField(String label, String key, TextEditingController ctrl, String example) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: _cs.onSurface.withValues(alpha: 0.45), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(fontSize: 15, color: _cs.onSurface),
            decoration: InputDecoration(
              hintText: 'None',
              hintStyle: TextStyle(color: _cs.onSurface.withValues(alpha: 0.26)),
              filled: true,
              fillColor: _cs.onSurface.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(14),
            ),
            onChanged: (v) => _commit(key, v),
          ),
          const SizedBox(height: 6),
          Text(example, style: TextStyle(color: _cs.onSurface.withValues(alpha: 0.38), fontSize: 11, height: 1.4)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _cs.onSurface.withValues(alpha: 0.45), letterSpacing: 0.6),
        ),
      );

  Widget _tile(String label, String key, {String? subtitle, VoidCallback? onTap}) {
    final v = _val(key);
    return ListTile(
      title: Text(label, style: TextStyle(color: _cs.onSurface)),
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(color: _cs.onSurface.withValues(alpha: 0.45), fontSize: 12))
          : (v.isNotEmpty ? Text(v, style: TextStyle(color: _cs.onSurface.withValues(alpha: 0.54), fontSize: 13)) : null),
      trailing: Icon(Icons.chevron_right, color: _cs.onSurface.withValues(alpha: 0.26), size: 20),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photoPath = _val(_kMedPhotoPath);
    final hasPhoto = photoPath.isNotEmpty && File(photoPath).existsSync();

    final cs = _cs;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Medical Info'),
      ),
      body: ListView(
        children: [
          _header('PROFILE PHOTO'),
          ListTile(
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: cs.onSurface.withValues(alpha: 0.12),
              backgroundImage: hasPhoto ? FileImage(File(photoPath)) : null,
              child: hasPhoto ? null : Icon(Icons.person_rounded, color: cs.onSurface.withValues(alpha: 0.38)),
            ),
            title: Text(hasPhoto ? 'Change Photo' : 'Add Photo', style: TextStyle(color: cs.onSurface)),
            subtitle: Text('Stored locally. Will not be transmitted', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12)),
            trailing: hasPhoto
                ? IconButton(
                    icon: Icon(Icons.delete_outline, color: cs.onSurface.withValues(alpha: 0.38)),
                    onPressed: _removePhoto,
                  )
                : Icon(Icons.chevron_right, color: cs.onSurface.withValues(alpha: 0.26), size: 20),
            onTap: _pickPhoto,
          ),
          _divider(),

          _header('BASIC INFORMATION'),
          _tile('Full Name', _kMedName, onTap: () => _editText(_kMedName, 'Full Name', cap: TextCapitalization.words)),
          _divider(),
          _tile('Gender', _kMedGender, onTap: () => _pickOption(_kMedGender, 'Gender', _genders)),
          _divider(),
          _tile('Age', _kMedAge, onTap: () => _editText(_kMedAge, 'Age', keyboard: TextInputType.number, cap: TextCapitalization.none)),
          _divider(),
          _tile('Blood Type', _kMedBloodType, onTap: () => _pickOption(_kMedBloodType, 'Blood Type', _bloodTypes)),
          _divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Do Not Resuscitate (DNR)', style: TextStyle(color: cs.onSurface, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text('Inform rescuers of your DNR status', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12)),
                    ],
                  ),
                ),
                Switch(
                  value: _val(_kMedDnr) == 'true',
                  onChanged: (v) => _commit(_kMedDnr, v.toString()),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'A Do Not Resuscitate (DNR) order tells emergency responders not to perform CPR or advanced life support if your heart stops or you stop breathing. This is an important legal and medical directive. Only enable this if you have a valid DNR order and ensure it reflects your current wishes.',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38), fontSize: 11, height: 1.5),
            ),
          ),

          _header('ALLERGIES'),
          _allergyField('Drug Allergy', _kMedAllergyDrug, _allergyDrugCtrl,
              'e.g. Penicillin, aspirin, sulfa drugs'),
          _allergyField('Food Allergy', _kMedAllergyFood, _allergyFoodCtrl,
              'e.g. Peanuts, shellfish, dairy'),
          _allergyField('Insect Allergy', _kMedAllergyInsect, _allergyInsectCtrl,
              'e.g. Bee stings, wasp stings, fire ants'),
          _allergyField('Latex Allergy', _kMedAllergyLatex, _allergyLatexCtrl,
              'e.g. Gloves, balloons, rubber bands'),

          _header('ADDITIONAL NOTES'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: TextField(
              controller: _noteCtrl,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(fontSize: 15, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: 'Any other medical information…',
                hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.26)),
                filled: true,
                fillColor: cs.onSurface.withValues(alpha: 0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
              onChanged: (v) => _commit(_kMedNotes, v),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Single-field edit dialog used by [_MedInfoEditScreenState._editText].
/// Owns its [TextEditingController] as a State field so Flutter disposes it
/// only when this widget is truly unmounted (after the dialog's exit
/// transition finishes) — disposing it manually right after `showDialog`
/// resolves is unsafe, since the route keeps rebuilding for several more
/// frames while it animates out.
class _EditTextDialog extends StatefulWidget {
  const _EditTextDialog({
    required this.label,
    required this.initial,
    required this.keyboard,
    required this.cap,
  });

  final String label;
  final String initial;
  final TextInputType keyboard;
  final TextCapitalization cap;

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.label),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: widget.keyboard,
        textCapitalization: widget.cap,
        decoration: InputDecoration(
          hintText: widget.label,
          hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.26)),
          filled: true,
          fillColor: cs.onSurface.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Save', style: TextStyle(color: Color(0xFF3E6FA8))),
        ),
      ],
    );
  }
}

// ─── Dashboard helper widgets ─────────────────────────────────────────────────

/// Live "Prepare for the worst" card: real overall % + the next few incomplete
/// items, pulled from the cached prep plan. Reloads on return from the tracker.
class _PrepSummaryCard extends StatefulWidget {
  const _PrepSummaryCard({super.key});

  @override
  State<_PrepSummaryCard> createState() => _PrepSummaryCardState();
}

class _PrepSummaryCardState extends State<_PrepSummaryCard> with WidgetsBindingObserver {
  final _service = DocService();
  bool _loading = true;
  bool _hasPlan = false;
  double _pct = 0;
  String _percentTemplate = '';
  // Flat display rows across all prep docs: a doc-title header or an item line.
  List<({bool header, String text})> _lines = const [];
  int _moreCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Auto-refresh the prepared % when the app returns to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Pull-to-refresh hook for the dashboard.
  Future<void> reload() => _load();

  // Aggregate every prep doc: overall % is the equal-weight average of each
  // doc's own weighted %, and the "to be improved" list is filled across docs
  // in order up to a fixed row budget so one short plan doesn't hog the card.
  // ponytail: equal weight per doc; weight by item count if that ever matters.
  Future<void> _load() async {
    final docs = await _service.loadDocs('prep');
    final loaded = <({Doc doc, Set<String> done})>[];
    for (final d in docs) {
      final vals = await _service.repo.getProgress(d.docId);
      loaded.add((doc: d, done: vals.keys.toSet()));
    }

    double fracSum = 0;
    var fracCount = 0;
    var totalIncomplete = 0;
    for (final e in loaded) {
      final roll = DocRollup(e.done);
      final fr = roll.overallFraction(e.doc.nodes);
      if (fr != null) {
        fracSum += fr;
        fracCount++;
      }
      totalIncomplete += roll.incompleteCount(e.doc.nodes);
    }

    const budget = 7; // rows shown before the "…and more" line
    final lines = <({bool header, String text})>[];
    for (final e in loaded) {
      final room = budget - lines.length;
      if (room < 2) break; // no space left for a header + at least one item
      final leaves = DocRollup(e.done).incompleteLeaves(e.doc.nodes, room - 1);
      if (leaves.isEmpty) continue; // this plan is complete — skip it
      lines.add((header: true, text: e.doc.title));
      for (final l in leaves) {
        lines.add((header: false, text: l));
      }
    }

    final shownItems = lines.where((l) => !l.header).length;
    _hasPlan = docs.isNotEmpty;
    _pct = fracCount == 0 ? 0 : fracSum / fracCount * 100;
    _percentTemplate = loaded.isNotEmpty ? loaded.first.doc.percentText : '';
    _lines = lines;
    _moreCount = totalIncomplete - shownItems;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openTracker() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const DocScreen(category: 'prep', title: 'Disaster Preparation'),
      ),
    );
    // Fill-state may have changed in the tracker — recompute % + rows.
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final pct = _hasPlan ? _pct : 0.0;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.5)),
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
                  _hasPlan && _percentTemplate.isNotEmpty
                      ? _percentTemplate.replaceAll('{p}', pct.round().toString())
                      : 'Set up your emergency preparedness:',
                  style: TextStyle(color: cs.onSurface, fontSize: 12),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 11,
                    backgroundColor: cs.onSurface.withValues(alpha: 0.24),
                    color: const Color(0xFF62E24B),
                  ),
                ),
                if (_lines.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'To be improved:',
                    style: TextStyle(
                        color: cs.onSurface, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  for (final l in _lines)
                    Padding(
                      padding: EdgeInsets.only(
                          left: l.header ? 0 : 8,
                          top: l.header ? 4 : 1,
                          bottom: l.header ? 2 : 0),
                      child: Text(
                        l.header ? l.text : '- ${l.text}',
                        style: TextStyle(
                          color: l.header
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.87),
                          fontSize: 12,
                          height: 1.4,
                          fontWeight: l.header ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  if (_moreCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('…and $_moreCount more',
                          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 12)),
                    ),
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
  const _NoticesBell({super.key});

  @override
  State<_NoticesBell> createState() => _NoticesBellState();
}

class _NoticesBellState extends State<_NoticesBell> {
  final _service = DocService();
  bool _unseen = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Re-checks unseen notices. Public so the Dashboard can refresh the bell
  /// dot on a periodic tick or manual pull-to-refresh, not just on open.
  Future<void> reload() async {
    final notices = await _service.loadNotices();
    final seen = await _service.seenNoticeIds();
    final unseen = notices.any((n) => !seen.contains((n['notice_id'] ?? '').toString()));
    if (mounted) setState(() => _unseen = unseen);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NoticesScreen()));
        reload();
      },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.notifications_none_rounded, color: cs.onSurface),
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
                  border: Border.all(color: cs.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Severity → accent color, shared by every dashboard alert-style card
/// ([_DangerZoneCard], [_NoticesBanner]) so the same red/amber/blue
/// vocabulary means the same thing everywhere, whether it's an admin notice
/// severity (critical/warning/advisory/info) or a geofence severity
/// (danger/warning/info) — same hex values [noticeColor] in notices_screen.dart
/// uses, kept in sync deliberately.
Color _alertColor(String sev) {
  switch (sev) {
    case 'critical':
    case 'danger':
      return const Color(0xFFD64545);
    case 'warning':
      return const Color(0xFFE0A800);
    default:
      return kAccentInk; // advisory / info
  }
}

/// Outline-only alert card: a thin severity-colored border and a small
/// tinted icon chip, no solid fill and no left accent bar — deliberately
/// distinct from Emergency Mode's solid pastel block just below it on the
/// same screen, so these read as secondary/informational rather than
/// competing with it. Shared by [_DangerZoneCard] and [_NoticesBanner].
class _AlertCard extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  const _AlertCard({
    required this.color,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.04),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: cs.onSurface)),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.62), height: 1.3)),
                ],
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: cs.onSurface.withValues(alpha: 0.3), size: 20),
          ],
        ],
      ),
    );
    final padded = Padding(padding: const EdgeInsets.only(bottom: 10), child: card);
    if (onTap == null) return padded;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(borderRadius: BorderRadius.circular(14), onTap: onTap, child: card),
    );
  }
}

/// Persistent card shown while the device's current GPS fix is inside an
/// admin-marked hazard zone — reactive off [GeofenceService.insideZones]
/// directly rather than its own fetch/reload cycle, so it updates the
/// instant a check (any of the periodic/background/pull-to-refresh paths)
/// runs. Distinct from the one-shot OS notification on entry: this stays up
/// for as long as the device remains inside, and disappears the moment it
/// leaves.
class _DangerZoneCard extends StatelessWidget {
  const _DangerZoneCard();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: GeofenceService.instance.insideZones,
      builder: (context, zones, _) {
        if (zones.isEmpty) return const SizedBox.shrink();
        // Worst zone first if inside several overlapping ones at once.
        const rank = {'danger': 2, 'warning': 1, 'info': 0};
        final z = zones.reduce((a, b) {
          final ra = rank[(a['severity'] ?? 'warning').toString()] ?? 0;
          final rb = rank[(b['severity'] ?? 'warning').toString()] ?? 0;
          return rb > ra ? b : a;
        });
        final sev = (z['severity'] ?? 'warning').toString();
        final name = (z['name'] ?? 'Hazard zone').toString();
        final hazard = (z['hazard_type'] ?? 'hazard').toString();
        return _AlertCard(
          color: _alertColor(sev),
          icon: Icons.warning_amber_rounded,
          title: 'You are inside: $name',
          subtitle: '$hazard area. Stay alert and move to safety if you can.',
        );
      },
    );
  }
}

/// Advisory / warning / critical notices as solid banners atop the dashboard
/// (info shows only as the bell dot). Tapping opens the full announcement.
/// A critical notice auto-opens its detail once, on app open.
class _NoticesBanner extends StatefulWidget {
  const _NoticesBanner({super.key});

  @override
  State<_NoticesBanner> createState() => _NoticesBannerState();
}

class _NoticesBannerState extends State<_NoticesBanner> {
  final _service = DocService();
  List<Map<String, dynamic>> _banners = const [];

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Re-fetches notices and re-derives the banner list. Public so the
  /// Dashboard can refresh it on a periodic tick or manual pull-to-refresh,
  /// not just once on open (Dashboard stays mounted indefinitely).
  Future<void> reload() async {
    final all = await _service.loadNotices();
    final seen = await _service.seenNoticeIds();
    // Banners for advisory/warning/critical that haven't been seen/dismissed yet.
    final banners = all
        .where((n) =>
            const ['advisory', 'warning', 'critical'].contains((n['severity'] ?? '').toString()) &&
            !seen.contains((n['notice_id'] ?? '').toString()))
        .toList();
    if (mounted) setState(() => _banners = banners);

    // OS notification for warning/critical, once each.
    final notified = await _service.notifiedNoticeIds();
    final toNotify = all.where((n) =>
        const ['warning', 'critical'].contains((n['severity'] ?? '').toString()) &&
        !notified.contains((n['notice_id'] ?? '').toString())).toList();
    for (final n in toNotify) {
      await NotificationService.instance.show(
        (n['title'] ?? '').toString(),
        (n['subtitle'] ?? '').toString(),
        high: true,
      );
    }
    if (toNotify.isNotEmpty) {
      await _service.markNoticesNotified(toNotify.map((n) => (n['notice_id'] ?? '').toString()));
    }

    // Critical auto-opens its full page once (newest unseen critical).
    Map<String, dynamic>? crit;
    for (final n in all) {
      if ((n['severity'] ?? '') == 'critical' && !seen.contains((n['notice_id'] ?? '').toString())) {
        crit = n;
        break;
      }
    }
    if (crit != null && mounted) {
      await _service.markNoticesSeen([(crit['notice_id'] ?? '').toString()]);
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

  Widget _banner(BuildContext context, Map<String, dynamic> n) {
    final sev = (n['severity'] ?? 'info').toString();
    final subtitle = (n['subtitle'] ?? '').toString();
    return _AlertCard(
      color: _alertColor(sev),
      icon: Icons.campaign_rounded,
      title: (n['title'] ?? '').toString(),
      subtitle: subtitle,
      onTap: () async {
        await _service.markNoticesSeen([(n['notice_id'] ?? '').toString()]);
        if (context.mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NoticeDetailScreen(notice: n)));
        }
        reload(); // banner disappears once seen
      },
    );
  }
}

/// Survival / First Aid entry rows — each opens its category guide list.
class _TipsCard extends StatelessWidget {
  const _TipsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        children: [
          _row(context, 'Survival Tips', 'survival'),
          Divider(height: 1, color: cs.onSurface.withValues(alpha: 0.26), indent: 22, endIndent: 22),
          _row(context, 'First Aid Tips', 'first_aid'),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String category) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
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
                    style: TextStyle(color: cs.onSurface, fontSize: 16)),
              ),
              Icon(Icons.chevron_right, color: cs.onSurface.withValues(alpha: 0.54), size: 20),
            ],
          ),
        ),
      );
  }
}
