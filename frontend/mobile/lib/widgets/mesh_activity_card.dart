import 'package:flutter/material.dart';

/// One line from a controller's statusStream, captured with the time it
/// arrived — shown on tap, since the on-screen list itself stays compact.
class LogEntry {
  LogEntry(this.message) : time = DateTime.now();

  final String message;
  final DateTime time;
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// The "Mesh Activity" log card from Figma nodes 8:107 / 10:272 — a rounded
/// translucent card listing dot-prefixed rows separated by thin dividers.
/// Used as the live status log for Increment 1 hardware testing.
///
/// Newest entry first — during testing, new lines arriving at the bottom
/// meant constantly scrolling down to see what just happened.
class MeshActivityCard extends StatelessWidget {
  const MeshActivityCard({
    super.key,
    required this.lines,
    this.scrollController,
    this.fontSize = 15,
  });

  final List<LogEntry> lines;
  final ScrollController? scrollController;
  final double fontSize;

  // The same screen's log keeps accumulating across repeated stop/start
  // cycles within one app session (switching modes, retrying after a
  // failure) — with nothing marking where one run ends and the next
  // begins, a long testing session reads as one confusing wall of mixed
  // lines. Both controllers already emit this exact line on every
  // start*Mode() call; reusing it (no controller changes needed) to render
  // it in bold, same row style as everything else.
  bool _isSessionStart(String line) => line.contains('mode started (deviceId=');

  /// Red = something actually went wrong. Amber = working as designed but
  /// worth a second look (retries, capability flags, TTL/dedupe). Green =
  /// real progress — a packet actually moved or a connection actually
  /// formed. Blue = plain info (state, mode started) — nothing to act on.
  Color _dotColorFor(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('fail') || lower.contains('error')) {
      return Colors.redAccent;
    }
    if (lower.contains('unexpectedly') ||
        lower.contains('will retry') ||
        lower.contains('cannot initiate') ||
        lower.contains('no wi-fi direct peers') ||
        lower.contains('no helper acks') ||
        lower.contains('already has everything') ||
        lower.contains('ttl exceeded') ||
        lower.contains('skipping')) {
      return Colors.amber;
    }
    if (lower.contains('received') ||
        lower.contains('sent') ||
        lower.contains('transmitted') ||
        lower.contains('relayed') ||
        lower.contains('stored') ||
        lower.contains('pulled') ||
        lower.contains('pushed') ||
        lower.contains('connected') ||
        lower.contains('written')) {
      return Colors.greenAccent;
    }
    return Colors.lightBlueAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(25),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: lines.isEmpty
          ? Text(
              'Waiting for activity…',
              style: TextStyle(color: Colors.white70, fontSize: fontSize),
            )
          : ListView.separated(
              controller: scrollController,
              itemCount: lines.length,
              separatorBuilder: (_, _) => const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: Colors.white24),
              ),
              itemBuilder: (context, index) {
                // Reversed: index 0 is the most recent entry.
                final entry = lines[lines.length - 1 - index];
                final isSessionStart = _isSessionStart(entry.message);
                return _LogRow(
                  entry: entry,
                  // A unique color (not reused by any of the 4 semantic
                  // categories below) so a new session's start is easy to
                  // spot at a glance while scrolling a long mixed log.
                  dotColor: isSessionStart
                      ? Colors.purpleAccent
                      : _dotColorFor(entry.message),
                  fontSize: fontSize,
                  isSessionStart: isSessionStart,
                );
              },
            ),
    );
  }
}

class _LogRow extends StatefulWidget {
  const _LogRow({
    required this.entry,
    required this.dotColor,
    required this.fontSize,
    required this.isSessionStart,
  });

  final LogEntry entry;
  final Color dotColor;
  final double fontSize;
  final bool isSessionStart;

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.entry.time;
    final timestamp =
        '${_twoDigits(t.hour)}:${_twoDigits(t.minute)}:${_twoDigits(t.second)}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 10),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: widget.dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.entry.message,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.fontSize,
                    fontWeight: widget.isSessionStart
                        ? FontWeight.bold
                        : FontWeight.normal,
                    height: 1.3,
                  ),
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      timestamp,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: widget.fontSize - 3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
