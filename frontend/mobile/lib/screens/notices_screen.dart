import 'package:flutter/material.dart';

import '../content/doc_controller.dart';
import '../content/doc_models.dart';
import '../content/doc_service.dart';
import '../screens/doc_screen.dart' show DocBody;
import '../services/geofence_service.dart';
import '../widgets/back_chevron.dart';

/// Renders a notice's full structure — sections, checklist fields, guide
/// pages, the lot — with the exact same widgets the survival/first_aid/prep
/// pages use ([DocBody]), not just a flattened block list. Falls back to
/// plain [body] text when there's no structure at all.
class NoticeBody extends StatefulWidget {
  final Map<String, dynamic> notice;
  final String body;
  const NoticeBody({super.key, required this.notice, required this.body});

  @override
  State<NoticeBody> createState() => _NoticeBodyState();
}

class _NoticeBodyState extends State<NoticeBody> {
  late final DocController _ctrl = DocController(DocService().repo);
  late final Future<void> _ready = _load();

  Future<void> _load() async {
    final raw = widget.notice['structure'];
    if (raw == null) return;
    final id = (widget.notice['noticeid'] ?? 'notice').toString();
    final doc = Doc.fromRow(
      docid: 'notice-$id',
      category: '',
      title: '',
      version: 0,
      updatedAt: '',
      structure: raw,
    );
    await _ctrl.load(doc);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        if (_ctrl.doc != null && _ctrl.doc!.nodes.isNotEmpty) {
          return DocBody(controller: _ctrl);
        }
        if (widget.body.isNotEmpty) {
          return Text(
            widget.body,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.87),
                fontSize: 15,
                height: 1.5),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

String fmtNoticeTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, $hh:$mm';
}

Color noticeColor(String sev) {
  switch (sev) {
    case 'critical':
      return const Color(0xFFD64545);
    case 'warning':
      return const Color(0xFFE0A800);
    case 'advisory':
      return const Color(0xFF3E6FA8);
    default:
      return Colors.black54; // info
  }
}

/// Announcements list (reached from the bell on the dashboard). A notice only
/// counts as read once its detail is actually opened, here or via the
/// dashboard banner — just opening this list no longer bulk-marks everything
/// seen, so the bell dot and each row's unread dot stay accurate.
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  final _service = DocService();
  late Future<({List<Map<String, dynamic>> notices, Set<String> seen})> _future = _load();

  Future<({List<Map<String, dynamic>> notices, Set<String> seen})> _load() async {
    final notices = await _service.loadNotices();
    final seen = await _service.seenNoticeIds();
    return (notices: notices, seen: seen);
  }

  /// Pull-to-refresh does more than just reload notices — same "any backend
  /// touch" piggyback as the dashboard (geofence check + local bundle sync).
  /// Awaits the fetch so the spinner stays down until fresh data is loaded
  /// (and admin edits actually show), instead of returning immediately.
  Future<void> _refresh() async {
    await GeofenceService.instance.check();
    final data = await _load();
    if (mounted) setState(() => _future = Future.value(data));
  }

  Future<void> _open(Map<String, dynamic> n) async {
    final id = (n['noticeid'] ?? '').toString();
    await _service.markNoticesSeen([id]);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoticeDetailScreen(notice: n)),
    );
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Notices'),
      ),
      body: FutureBuilder<({List<Map<String, dynamic>> notices, Set<String> seen})>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final notices = snap.data?.notices ?? const [];
          final seen = snap.data?.seen ?? const {};
          if (notices.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(children: [
                const SizedBox(height: 120),
                Icon(Icons.notifications_none, size: 48, color: cs.onSurface.withValues(alpha: 0.26)),
                const SizedBox(height: 12),
                const Center(child: Text('No notices', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                const SizedBox(height: 6),
                Center(child: Text('You’re all caught up.', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 13))),
              ]),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              itemCount: notices.length,
              separatorBuilder: (context, index) => Divider(height: 1, color: cs.onSurface.withValues(alpha: 0.12), indent: 16, endIndent: 16),
              itemBuilder: (context, i) {
                final n = notices[i];
                final id = (n['noticeid'] ?? '').toString();
                final unread = !seen.contains(id);
                final when = fmtNoticeTime((n['updatedat'] ?? n['createdat'])?.toString());
                final sev = (n['severity'] ?? 'info').toString();
                return ListTile(
                  title: Row(
                    children: [
                      Flexible(
                        child: Text((n['title'] ?? '').toString(),
                            style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600)),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(color: Color(0xFFD64545), shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (when.isNotEmpty) ...[
                        Text(when, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))),
                        const SizedBox(width: 8),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: noticeColor(sev), borderRadius: BorderRadius.circular(999)),
                        child: Text(sev.toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  onTap: () => _open(n),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Full announcement.
class NoticeDetailScreen extends StatelessWidget {
  final Map<String, dynamic> notice;
  const NoticeDetailScreen({super.key, required this.notice});

  @override
  Widget build(BuildContext context) {
    final sev = (notice['severity'] ?? 'info').toString();
    final subtitle = (notice['subtitle'] ?? '').toString();
    final body = (notice['body'] ?? '').toString();
    final created = fmtNoticeTime(notice['createdat']?.toString());
    final updated = fmtNoticeTime(notice['updatedat']?.toString());
    final stamp = created.isEmpty
        ? ''
        : (updated.isNotEmpty && updated != created ? 'Posted $created · Updated $updated' : 'Posted $created');
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: const Text('Notice'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: noticeColor(sev), borderRadius: BorderRadius.circular(999)),
              child: Text(sev.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          Text((notice['title'] ?? '').toString(),
              style: TextStyle(color: cs.onSurface, fontSize: 22, fontWeight: FontWeight.bold)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 15)),
          ],
          if (stamp.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(stamp, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38), fontSize: 12)),
          ],
          const SizedBox(height: 16),
          NoticeBody(notice: notice, body: body),
        ],
      ),
    );
  }
}
