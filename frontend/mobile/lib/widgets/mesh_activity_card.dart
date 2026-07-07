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
/// Newest entry at the TOP, and the view must never move when a new entry
/// arrives while the user is scrolled down reading/screenshotting. A plain
/// top-anchored ListView can't do that: a prepend shifts everything the same
/// frame and any jumpTo correction lands one frame late (a visible flinch).
/// Instead this is a center-anchored CustomScrollView: the scroll offset is
/// measured from an anchor sliver, entries newer than the anchor snapshot
/// live in a sliver that grows UPWARD from it, so a new entry only extends
/// minScrollExtent — nothing currently on screen moves, by construction.
/// Only when the user is already at the very top does the card follow the
/// newest entry (matching the old behaviour of new lines sliding in).
class MeshActivityCard extends StatefulWidget {
  const MeshActivityCard({
    super.key,
    required this.lines,
    this.scrollController,
    this.fontSize = 15,
  });

  final List<LogEntry> lines;
  final ScrollController? scrollController;
  final double fontSize;

  @override
  State<MeshActivityCard> createState() => _MeshActivityCardState();
}

class _MeshActivityCardState extends State<MeshActivityCard> {
  ScrollController? _ownController;

  // Anchor for the two-sliver viewport in build(). Stable across rebuilds
  // (state field) so the viewport keeps measuring offsets from the same
  // sliver for the lifetime of the card.
  final Key _centerKey = UniqueKey();

  // lines[0.._anchorCount) render in the center sliver (downward from the
  // anchor); lines[_anchorCount..] render in the sliver above it, which grows
  // upward into negative scroll offsets. Because the offset is measured from
  // the anchor, entries added above extend minScrollExtent without moving
  // anything the user is currently looking at.
  // Assigned in initState, NOT as `late =` field initializers: a late lazy
  // initializer evaluates at first READ, and _lastCount's first read is
  // inside didUpdateWidget — after the list already grew — which silently
  // made every growth check compare the new length against itself.
  late List<LogEntry> _boundTo;
  late int _anchorCount;
  // The screens mutate the SAME List instance in place (_rawLog.add) and
  // rebuild — oldWidget.lines IS widget.lines, so growth is only detectable
  // against this snapshot.
  late int _lastCount;

  @override
  void initState() {
    super.initState();
    _boundTo = widget.lines;
    _anchorCount = widget.lines.length;
    _lastCount = widget.lines.length;
  }

  ScrollController get _controller =>
      widget.scrollController ?? (_ownController ??= ScrollController());

  @override
  void didUpdateWidget(MeshActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_boundTo, widget.lines)) {
      // The Settings detailed-logging toggle swaps which List backs the card
      // (_rawLog vs _displayLog) — the anchor split is meaningless against
      // the new list. Rebase on it and show its newest entries.
      _boundTo = widget.lines;
      _anchorCount = widget.lines.length;
      _lastCount = widget.lines.length;
      _jumpToTopAfterFrame();
      return;
    }
    final grew = widget.lines.length > _lastCount;
    _lastCount = widget.lines.length;
    if (!grew) return;
    if (!_controller.hasClients) {
      // No scroll view attached yet — the empty-state placeholder was showing
      // (or the list hasn't laid out). Rebase so this build puts everything in
      // the center sliver; without this, entries added before first layout
      // would live above the anchor and render off-screen with no way to
      // follow them.
      _anchorCount = widget.lines.length;
      return;
    }
    final pos = _controller.position;
    // At the very top when this entry arrived → keep following, so the new
    // line slides into view. Scrolled down → do nothing at all; the center
    // anchor already holds the view perfectly still.
    if (pos.pixels <= pos.minScrollExtent + 1) _jumpToTopAfterFrame();
  }

  void _jumpToTopAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _controller;
      if (c.hasClients) c.jumpTo(c.position.minScrollExtent);
    });
  }

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  // The same screen's log keeps accumulating across repeated stop/start
  // cycles within one app session (switching modes, retrying after a
  // failure) — with nothing marking where one run ends and the next
  // begins, a long testing session reads as one confusing wall of mixed
  // lines. Both controllers already emit this exact line on every
  // start*Mode() call; reusing it (no controller changes needed) to render
  // it in bold, same row style as everything else.
  bool _isSessionStart(String line) =>
      line.contains('mode started (deviceId=') || // raw
      (line.contains('mode started.') &&
          (line.startsWith('Victim') || line.startsWith('Helper')));

  /// Red = something actually went wrong. Amber = working as designed but
  /// worth a second look (retries, capability flags, TTL/dedupe). Green =
  /// real progress, a packet actually moved or a connection actually
  /// formed. Blue = plain info (state, mode started), nothing to act on.
  Color _dotColorFor(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('fail') || lower.contains('error')) {
      return Colors.redAccent;
    }
    if (lower.startsWith('paused ') ||
        lower.contains('unexpectedly') ||
        lower.contains('will retry') ||
        lower.contains('cannot initiate') ||
        lower.contains('no wi-fi direct peers') ||
        lower.contains('no helper acks') ||
        lower.contains('already has everything') ||
        lower.contains('ttl exceeded') ||
        lower.contains('skipping') ||
        lower.contains('could not') ||
        lower.contains('restarting') ||
        lower.contains('resetting') ||
        lower.contains('no helpers detected') ||
        lower.contains('received nothing')) {
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
        lower.contains('written') ||
        lower.contains('downloaded')) {
      return Colors.greenAccent;
    }
    return Colors.lightBlueAccent;
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    // Defensive: never index past the live list if it somehow shrank.
    final anchorCount =
        _anchorCount <= lines.length ? _anchorCount : lines.length;
    final newCount = lines.length - anchorCount;
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
              style: TextStyle(
                color: Colors.white70,
                fontSize: widget.fontSize,
              ),
            )
          : CustomScrollView(
              controller: _controller,
              center: _centerKey,
              slivers: [
                // Entries newer than the anchor snapshot. This sliver sits
                // BEFORE the center, so it grows upward: child 0 is the row
                // just above the center sliver, and the newest entry ends up
                // at the very top — the visual order stays newest→oldest
                // across both slivers.
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildEntry(lines, anchorCount + index),
                    childCount: newCount,
                  ),
                ),
                // The anchor: entries that existed when the card was built
                // (or when the log-detail toggle rebased it), newest first.
                SliverList(
                  key: _centerKey,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        _buildEntry(lines, anchorCount - 1 - index),
                    childCount: anchorCount,
                  ),
                ),
              ],
            ),
    );
  }

  /// One log row plus the divider below it — reproduces the old
  /// ListView.separated look. The bottom-most row (entry 0, the oldest)
  /// carries no divider.
  Widget _buildEntry(List<LogEntry> lines, int i) {
    final entry = lines[i];
    final isSessionStart = _isSessionStart(entry.message);
    return Column(
      children: [
        _LogRow(
          entry: entry,
          // A unique color (not reused by any of the 4 semantic categories
          // in _dotColorFor) so a new session's start is easy to spot at a
          // glance while scrolling a long mixed log.
          dotColor: isSessionStart
              ? Colors.purpleAccent
              : _dotColorFor(entry.message),
          fontSize: widget.fontSize,
          isSessionStart: isSessionStart,
        ),
        if (i > 0)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: Colors.white24),
          ),
      ],
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
