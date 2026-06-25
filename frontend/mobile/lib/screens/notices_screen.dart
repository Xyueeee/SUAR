import 'package:flutter/material.dart';

import '../content/block_renderer.dart';
import '../content/content_models.dart';
import '../content/doc_models.dart';
import '../content/doc_service.dart';
import '../widgets/back_chevron.dart';

/// Flattens a notice's block-doc structure into a renderable block list (guide
/// pages' blocks; sections recursed). Falls back to plain [body] text.
List<Widget> noticeContent(Map<String, dynamic> notice, String body) {
  final blocks = <Block>[];
  final raw = notice['structure'];
  if (raw != null) {
    final doc = Doc.fromRow(docid: 'n', category: '', title: '', version: 0, updatedAt: '', structure: raw);
    void walk(List<DocNode> ns) {
      for (final n in ns) {
        if (n.isGuide) {
          for (final p in n.pages) {
            blocks.addAll(p.blocks);
          }
        } else if (n.isSection) {
          walk(n.children);
        }
      }
    }
    walk(doc.nodes);
  }
  if (blocks.isNotEmpty) return buildBlocks(blocks);
  if (body.isNotEmpty) {
    return [Text(body, style: const TextStyle(color: Colors.black87, fontSize: 15, height: 1.5))];
  }
  return const [];
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

/// Announcements list (reached from the bell on the dashboard). Opening it marks
/// all current notices as seen (clears the bell dot).
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  final _service = DocService();
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final notices = await _service.loadNotices();
    await _service.markNoticesSeen(notices.map((n) => (n['noticeid'] ?? '').toString()));
    return notices;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: const Text('Notices'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final notices = snap.data ?? const [];
          if (notices.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async => setState(() => _future = _load()),
              child: ListView(children: const [
                SizedBox(height: 120),
                Icon(Icons.notifications_none, size: 48, color: Colors.black26),
                SizedBox(height: 12),
                Center(child: Text('No notices', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                SizedBox(height: 6),
                Center(child: Text('You’re all caught up.', style: TextStyle(color: Colors.black54, fontSize: 13))),
              ]),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = _load()),
            child: ListView.separated(
              itemCount: notices.length,
              separatorBuilder: (context, index) => const Divider(height: 1, color: Colors.black12, indent: 16, endIndent: 16),
              itemBuilder: (context, i) {
                final n = notices[i];
                final when = fmtNoticeTime((n['updatedat'] ?? n['createdat'])?.toString());
                return ListTile(
                  title: Text((n['title'] ?? '').toString(),
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
                  subtitle: when.isEmpty ? null : Text(when, style: const TextStyle(color: Colors.black54)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => NoticeDetailScreen(notice: n)),
                  ),
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
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
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
              style: const TextStyle(color: Colors.black, fontSize: 22, fontWeight: FontWeight.bold)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 15)),
          ],
          if (stamp.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(stamp, style: const TextStyle(color: Colors.black38, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          ...noticeContent(notice, body),
        ],
      ),
    );
  }
}
