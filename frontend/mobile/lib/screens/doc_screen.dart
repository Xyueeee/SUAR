import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../content/block_renderer.dart';
import '../content/doc_controller.dart';
import '../content/doc_models.dart';
import '../content/doc_service.dart';
import '../help/help_tour.dart';
import '../services/geofence_service.dart';
import '../theme.dart' show kPanelDark;
import '../widgets/back_chevron.dart';

const Color _green = Color(0xFF4CAF50);
const Color _bar = Color(0xFF62E24B);
const Color _accent = Color(0xFF3E6FA8);

/// Carries the victim mode's live radio status into content screens opened
/// from victim mode. Injected via ThemeData.copyWith when navigating so every
/// sub-screen in the stack can show the live pill without prop drilling.
@immutable
class VictimRadioStatus extends ThemeExtension<VictimRadioStatus> {
  final ValueListenable<String> listenable;
  const VictimRadioStatus(this.listenable);

  @override
  VictimRadioStatus copyWith({ValueListenable<String>? listenable}) =>
      VictimRadioStatus(listenable ?? this.listenable);

  @override
  ThemeExtension<VictimRadioStatus> lerp(
      ThemeExtension<VictimRadioStatus>? other, double t) =>
      this;
}

/// Live pill shown in AppBar actions when [VictimRadioStatus] is in the theme.
/// Returns [SizedBox.shrink] when navigated from a non-victim screen.
/// Text color inherits from the AppBar's foreground so it works on both
/// dark (victim doc screens) and light (medical info) AppBars; only the
/// dot changes color to reflect the current radio state.
class RadioPill extends StatelessWidget {
  const RadioPill({super.key});

  @override
  Widget build(BuildContext context) {
    final ext = Theme.of(context).extension<VictimRadioStatus>();
    if (ext == null) return const SizedBox.shrink();
    return ValueListenableBuilder<String>(
      valueListenable: ext.listenable,
      builder: (ctx, status, _) {
        final dotColor = switch (status) {
          'Sending'    => Colors.amber,
          'Connecting' => const Color(0xFF4CAF50),
          'BT Link'    => const Color(0xFF6AA8D5),
          _            => const Color(0xFFE05555),
        };
        final label = status == 'BT Link' ? 'Connecting' : status;
        return Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7, height: 7,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                ),
                const SizedBox(width: 5),
                // Text color intentionally unset — inherits AppBar foreground color.
                Text(label, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Navigator.push exits the current Theme InheritedWidget subtree — new routes
// get the app-level theme, not any Theme wrapper around the calling widget.
// Capture the current theme and re-wrap so the entire pushed sub-tree
// (including any further pushes that _SectionScreen / _GuideViewer make) stays
// in whatever theme was active when the user tapped.
void _pushWithTheme(BuildContext context, Widget screen) {
  final theme = Theme.of(context);
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => Theme(data: theme, child: screen)),
  );
}

/// Unified renderer for any category (survival / first_aid / preparation /
/// prep). Renders the most-recent published doc: an optional overall % card,
/// then its top-level nodes. Sections drill in (prep-style cards); guide items
/// open a paged/scroll viewer; field items are checkboxes / inputs.
class DocScreen extends StatefulWidget {
  final String category;
  final String title;
  const DocScreen({super.key, required this.category, required this.title});

  @override
  State<DocScreen> createState() => _DocScreenState();
}

class _DocScreenState extends State<DocScreen> {
  final _service = DocService();
  late final DocController _ctrl = DocController(_service.repo);
  late final Future<void> _ready = _init();

  // Help tour only applies to prep plans (percent roll-up + checklists).
  bool get _isPrep => widget.category == 'prep';
  final _kPercent = GlobalKey();
  late final HelpTourController _help = HelpTourController([
    HelpStep(
      targetKey: _kPercent,
      title: 'Your overall progress',
      body: const [
        'A weighted roll-up of everything you have checked off below.',
        'It reaches 100% once your whole plan is complete.',
      ],
    ),
    const HelpStep(
      title: 'Working through the plan',
      body: [
        'Tap any item to mark it done. Progress saves automatically.',
        'Sections open up to reveal their own checklists.',
        'Everything here works offline once loaded.',
      ],
    ),
  ]);

  Future<void> _init() async {
    final docs = await _service.loadDocs(widget.category);
    if (docs.isNotEmpty) await _ctrl.load(_merge(docs));
  }

  Future<void> _refresh() async {
    final docs = await _service.loadDocs(widget.category);
    if (docs.isNotEmpty) await _ctrl.load(_merge(docs));
    // Pull-to-refresh does more than just this page's own content — same
    // "any backend touch" piggyback as the dashboard (geofence check + local
    // bundle sync), so every page that supports pulling down does it too.
    await GeofenceService.instance.check();
    if (mounted) setState(() {});
  }

  // Multiple docs per category (admin can split "one section per doc" and
  // reorder them) are concatenated, in OrderIndex order, into one rendered doc.
  Doc _merge(List<Doc> docs) {
    if (docs.length == 1) return docs.first;
    return Doc(
      docId: 'cat-${widget.category}',
      category: widget.category,
      title: docs.first.title,
      version: 0,
      usePercent: docs.any((d) => d.usePercent),
      percentText: docs.firstWhere((d) => d.usePercent, orElse: () => docs.first).percentText,
      nodes: [for (final d in docs) ...d.nodes],
      structureJson: '',
      updatedAt: '',
    );
  }

  @override
  void dispose() {
    _help.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: Text(widget.title),
        actions: [
          if (_isPrep) HelpButton(controller: _help),
          const RadioPill(),
        ],
      ),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_ctrl.doc == null || _ctrl.doc!.nodes.isEmpty) {
            return _Empty(onRefresh: _refresh);
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [DocBody(controller: _ctrl, percentKey: _isPrep ? _kPercent : null)],
            ),
          );
        },
      ),
    );
  }
}

/// Renders a loaded [DocController]'s doc — optional overall % card, then its
/// top-level nodes (sections/guides/fields) — with no Scaffold/AppBar of its
/// own, so any screen with its own header can drop it straight into a
/// ListView (the category page does; so does the notice detail screen, for
/// the exact same section/checklist/guide rendering a notice's structure can
/// carry, not just its plain-text blocks).
class DocBody extends StatelessWidget {
  final DocController controller;

  /// Optional key placed on the overall-percent card so the help tour can
  /// spotlight it. Null on non-prep pages (which have no percent card).
  final Key? percentKey;
  const DocBody({super.key, required this.controller, this.percentKey});

  @override
  Widget build(BuildContext context) {
    final doc = controller.doc;
    if (doc == null || doc.nodes.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (doc.usePercent) ...[
              _PercentCard(
                key: percentKey,
                text: doc.percentText.replaceAll('{p}', controller.overallPercent.round().toString()),
                value: controller.overallPercent / 100,
              ),
              const SizedBox(height: 16),
            ],
            ..._topLevelWidgets(controller, doc.nodes),
          ],
        );
      },
    );
  }
}

/// Top-level nodes used to render very differently depending on kind: a
/// section got its own white bordered card, but a guide/field at the SAME
/// top level got its own standalone treatment too (a big blue "guide" card,
/// or its own little grey box) — one card style per sibling instead of the
/// single shared grey panel-with-dividers that nested children inside a
/// section get via [_ChildPanel]. A guide/field shouldn't look different
/// just because it happens to sit at the root instead of one level deeper,
/// so consecutive non-section siblings here are grouped into ONE shared
/// panel, the exact same look [_ChildPanel] gives a section's children.
/// Sections still get their own card (they're a container, not a leaf).
List<Widget> _topLevelWidgets(DocController controller, List<DocNode> nodes) {
  final out = <Widget>[];
  var i = 0;
  while (i < nodes.length) {
    if (nodes[i].isSection) {
      out.add(_SectionCard(controller: controller, node: nodes[i], path: '$i'));
      out.add(const SizedBox(height: 16));
      i++;
      continue;
    }
    final runNodes = <DocNode>[];
    final runPaths = <String>[];
    while (i < nodes.length && !nodes[i].isSection) {
      runNodes.add(nodes[i]);
      runPaths.add('$i');
      i++;
    }
    out.add(_ChildPanel(controller: controller, nodes: runNodes, paths: runPaths));
    out.add(const SizedBox(height: 16));
  }
  return out;
}

class _SectionCard extends StatelessWidget {
  final DocController controller;
  final DocNode node;
  final String path;
  const _SectionCard({required this.controller, required this.node, required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = controller.rollup.nodePercent(node, path);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle, big: true)),
              if (node.usePercent) ...[
                const SizedBox(width: 12),
                Text('${pct.round()}%',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 14)),
              ],
            ],
          ),
          if (node.usePercent) ...[
            const SizedBox(height: 10),
            _ProgressBar(value: pct / 100),
          ],
          const SizedBox(height: 14),
          _ChildPanel(
            controller: controller,
            nodes: node.children,
            paths: [for (var i = 0; i < node.children.length; i++) '$path.$i'],
          ),
        ],
      ),
    );
  }
}

/// Full-screen drill-in for a nested section.
class _SectionScreen extends StatelessWidget {
  final DocController controller;
  final DocNode node;
  final String path;
  const _SectionScreen({required this.controller, required this.node, required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: Text(node.title.isEmpty ? 'Section' : node.title),
        actions: const [RadioPill()],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final pct = controller.rollup.nodePercent(node, path);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (node.subtitle != null && node.subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(node.subtitle!,
                      style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 14)),
                ),
              if (node.usePercent) ...[
                _ProgressBar(value: pct / 100),
                const SizedBox(height: 6),
                Text('${pct.round()}% complete',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 13)),
                const SizedBox(height: 14),
              ],
              _ChildPanel(
                controller: controller,
                nodes: node.children,
                paths: [for (var i = 0; i < node.children.length; i++) '$path.$i'],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ChildPanel extends StatelessWidget {
  final DocController controller;
  final List<DocNode> nodes;
  final List<String> paths;
  const _ChildPanel({required this.controller, required this.nodes, required this.paths});

  bool _isInline(DocNode n) => n.isGuide && n.layout == 'inline';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (nodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('Nothing here yet.',
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45))),
      );
    }
    // Inline content renders bare (no grey panel); every other kind groups into
    // the grey rounded panel with dividers. Split into alternating segments so
    // an inline guide never sits inside the box.
    final segments = <Widget>[];
    var run = <int>[];
    void flush() {
      if (run.isEmpty) return;
      segments.add(_greyPanel(context, List<int>.from(run)));
      run = [];
    }

    for (var i = 0; i < nodes.length; i++) {
      if (_isInline(nodes[i])) {
        flush();
        segments.add(_InlineGuide(node: nodes[i]));
      } else {
        run.add(i);
      }
    }
    flush();

    if (segments.length == 1) return segments.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          segments[i],
        ],
      ],
    );
  }

  Widget _greyPanel(BuildContext context, List<int> idx) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var k = 0; k < idx.length; k++) ...[
            if (k > 0)
              Divider(
                height: 1,
                color: cs.onSurface.withValues(alpha: 0.12),
                indent: 14,
                endIndent: 14,
              ),
            _ChildRow(controller: controller, node: nodes[idx[k]], path: paths[idx[k]]),
          ],
        ],
      ),
    );
  }
}

class _ChildRow extends StatelessWidget {
  final DocController controller;
  final DocNode node;
  final String path;
  const _ChildRow({required this.controller, required this.node, required this.path});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (node.isSection) {
      final pct = controller.rollup.nodePercent(node, path);
      return InkWell(
        onTap: () => _pushWithTheme(
          context,
          _SectionScreen(controller: controller, node: node, path: path),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
              if (node.usePercent)
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 6),
                  child: Text('${pct.round()}%',
                      style: TextStyle(
                          color: pct >= 99.95 ? _green : cs.onSurface.withValues(alpha: 0.54),
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
              Icon(Icons.chevron_right, color: cs.onSurface.withValues(alpha: 0.38)),
            ],
          ),
        ),
      );
    }
    if (node.isGuide) {
      // 'inline' = show the content directly in place, no tap-through button
      // (used for notices and any doc that just wants direct text/content).
      if (node.layout == 'inline') return _InlineGuide(node: node);
      return InkWell(
        onTap: () => _pushWithTheme(context, _GuideViewer(node: node)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
              Icon(Icons.chevron_right, color: cs.onSurface.withValues(alpha: 0.38)),
            ],
          ),
        ),
      );
    }
    return _FieldRow(controller: controller, node: node, path: path);
  }
}

class _FieldRow extends StatefulWidget {
  final DocController controller;
  final DocNode node;
  final String path;
  const _FieldRow({required this.controller, required this.node, required this.path});

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  TextEditingController? _tc;

  @override
  void initState() {
    super.initState();
    if (widget.node.kind == 'text' || widget.node.kind == 'number') {
      _tc = TextEditingController(text: widget.controller.valueOf(widget.path));
    }
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    _tc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final node = widget.node;
    if (node.kind == 'text' || node.kind == 'number') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TitleSub(title: node.title, subtitle: node.subtitle),
            const SizedBox(height: 4),
            TextField(
              controller: _tc,
              keyboardType: node.kind == 'number' ? TextInputType.number : TextInputType.text,
              style: const TextStyle(fontSize: 15),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Tap to fill in',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              onChanged: (v) => widget.controller.setText(widget.path, v),
            ),
          ],
        ),
      );
    }
    final checked = widget.controller.isChecked(widget.path);
    return InkWell(
      onTap: () => widget.controller.toggle(widget.path, !checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              activeColor: _green,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              side: BorderSide(color: cs.onSurface.withValues(alpha: 0.38), width: 2),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => widget.controller.toggle(widget.path, v ?? false),
            ),
            const SizedBox(width: 10),
            Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
          ],
        ),
      ),
    );
  }
}

/// Inline content — a guide with layout 'inline'. Renders its blocks directly
/// where the node sits: no tap-through row, no drill-in screen, no wrapping
/// box, so a notice or doc shows its text the moment the page opens. Same
/// output as the web editor's inline preview (all pages' blocks, concatenated).
class _InlineGuide extends StatelessWidget {
  final DocNode node;
  const _InlineGuide({required this.node});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final blocks = [for (final p in node.pages) ...p.blocks];
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: buildBlocks(blocks, textColor: cs.onSurface, brightness: cs.brightness),
    );
  }
}

/// Guide viewer — `steps` (swipe + prev/next + dots) or `scroll` (list).
class _GuideViewer extends StatefulWidget {
  final DocNode node;
  const _GuideViewer({required this.node});

  @override
  State<_GuideViewer> createState() => _GuideViewerState();
}

class _GuideViewerState extends State<_GuideViewer> {
  final _pageCtrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pages = widget.node.pages;
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: Text(widget.node.title),
        actions: const [RadioPill()],
      ),
      body: pages.isEmpty
          ? Center(
              child: Text('No content yet.',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54))))
          : (widget.node.layout == 'scroll' ? _scroll(context, pages) : _paged(context, pages)),
    );
  }

  Widget _pageContent(BuildContext context, DocPage page) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (page.title != null && page.title!.isNotEmpty)
            Text(page.title!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          if (page.subtitle != null && page.subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(page.subtitle!,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 13)),
            ),
          const SizedBox(height: 12),
          ...buildBlocks(page.blocks, textColor: cs.onSurface, brightness: cs.brightness),
        ],
      ),
    );
  }

  Widget _scroll(BuildContext context, List<DocPage> pages) => ListView.separated(
        itemCount: pages.length,
        separatorBuilder: (ctx, _) => Divider(
          height: 1,
          thickness: 6,
          color: Theme.of(ctx).brightness == Brightness.dark
              ? kPanelDark
              : Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.07),
        ),
        itemBuilder: (ctx, i) => _pageContent(ctx, pages[i]),
      );

  Widget _paged(BuildContext context, List<DocPage> pages) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        LinearProgressIndicator(
          value: pages.isEmpty ? 0 : (_page + 1) / pages.length,
          minHeight: 3,
          backgroundColor: cs.onSurface.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark ? 0.24 : 0.12),
          valueColor: const AlwaysStoppedAnimation(_accent),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _page = i),
            itemCount: pages.length,
            itemBuilder: (ctx, i) => _pageContent(ctx, pages[i]),
          ),
        ),
        _StepNav(
          page: _page,
          total: pages.length,
          onPrev: _page > 0
              ? () => _pageCtrl.previousPage(
                  duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
              : null,
          onNext: _page < pages.length - 1
              ? () => _pageCtrl.nextPage(
                  duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
              : null,
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------- //
// Small shared widgets                                                         //
// --------------------------------------------------------------------------- //

class _TitleSub extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool big;
  const _TitleSub({required this.title, this.subtitle, this.big = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.isEmpty ? 'Untitled' : title,
          style: TextStyle(
            color: cs.onSurface,
            fontSize: big ? 18 : 16,
            fontWeight: big ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!,
                style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.54), fontSize: 12, height: 1.3)),
          ),
      ],
    );
  }
}

class _PercentCard extends StatelessWidget {
  final String text;
  final double value;
  const _PercentCard({super.key, required this.text, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(color: cs.onSurface, fontSize: 13)),
          const SizedBox(height: 10),
          _ProgressBar(value: value),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final double value;
  const _ProgressBar({required this.value});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: 11,
          backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
          valueColor: const AlwaysStoppedAnimation(_bar),
        ),
      );
}

Widget _navPill(
  BuildContext context,
  IconData icon,
  String label,
  VoidCallback? onTap, {
  bool iconLeading = true,
}) {
  final cs = Theme.of(context).colorScheme;
  final enabled = onTap != null;
  final color = enabled ? _accent : cs.onSurface.withValues(alpha: 0.26);
  final row = <Widget>[
    Icon(icon, size: 18, color: color),
    const SizedBox(width: 2),
    Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
  ];
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(999),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: iconLeading ? row : row.reversed.toList(),
      ),
    ),
  );
}

class _StepNav extends StatelessWidget {
  final int page;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _StepNav({required this.page, required this.total, this.onPrev, this.onNext});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.onSurface.withValues(alpha: 0.12))),
        ),
        child: Row(
          children: [
            _navPill(context, Icons.chevron_left, 'Prev', onPrev),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Step ${page + 1} of $total',
                      style: TextStyle(
                          fontSize: 13, color: cs.onSurface.withValues(alpha: 0.54))),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < total; i++)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == page ? _accent : cs.onSurface.withValues(alpha: 0.26),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            _navPill(context, Icons.chevron_right, 'Next', onNext, iconLeading: false),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final Future<void> Function() onRefresh;
  const _Empty({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.inbox_outlined, size: 48, color: cs.onSurface.withValues(alpha: 0.26)),
          const SizedBox(height: 12),
          const Center(
              child: Text("It's empty here",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
          const SizedBox(height: 6),
          Center(
            child: Text('Pull down to refresh.',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.54), fontSize: 13)),
          ),
        ],
      ),
    );
  }
}