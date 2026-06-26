import 'package:flutter/material.dart';

import '../content/block_renderer.dart';
import '../content/doc_controller.dart';
import '../content/doc_models.dart';
import '../content/doc_service.dart';
import '../widgets/back_chevron.dart';

const Color _green = Color(0xFF4CAF50);
const Color _bar = Color(0xFF62E24B);
const Color _panel = Color(0xFFEDEDED);
const Color _accent = Color(0xFF3E6FA8);

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

  Future<void> _init() async {
    final docs = await _service.loadDocs(widget.category);
    if (docs.isNotEmpty) await _ctrl.load(_merge(docs));
  }

  Future<void> _refresh() async {
    final docs = await _service.loadDocs(widget.category);
    if (docs.isNotEmpty) await _ctrl.load(_merge(docs));
    if (mounted) setState(() {});
  }

  // Multiple docs per category (admin can split "one section per doc" and
  // reorder them) are concatenated, in OrderIndex order, into one rendered doc.
  Doc _merge(List<Doc> docs) {
    if (docs.length == 1) return docs.first;
    return Doc(
      docid: 'cat-${widget.category}',
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
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: Text(widget.title),
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
              children: [DocBody(controller: _ctrl)],
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
  const DocBody({super.key, required this.controller});

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
    final pct = controller.rollup.nodePercent(node, path);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle, big: true)),
              if (node.usePercent)
                Text('${pct.round()}%', style: const TextStyle(color: Colors.black54, fontSize: 14)),
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
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: Text(node.title.isEmpty ? 'Section' : node.title),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final pct = controller.rollup.nodePercent(node, path);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (node.subtitle != null && node.subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(node.subtitle!, style: const TextStyle(color: Colors.black54, fontSize: 14)),
                ),
              if (node.usePercent) ...[
                _ProgressBar(value: pct / 100),
                const SizedBox(height: 6),
                Text('${pct.round()}% complete', style: const TextStyle(color: Colors.black54, fontSize: 13)),
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

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Nothing here yet.', style: TextStyle(color: Colors.black45)),
      );
    }
    return Container(
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          for (var i = 0; i < nodes.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Colors.black12, indent: 14, endIndent: 14),
            _ChildRow(controller: controller, node: nodes[i], path: paths[i]),
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
    if (node.isSection) {
      final pct = controller.rollup.nodePercent(node, path);
      return InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _SectionScreen(controller: controller, node: node, path: path),
        )),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
              if (node.usePercent)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('${pct.round()}%',
                      style: TextStyle(
                          color: pct >= 99.95 ? _green : Colors.black54,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
              const Icon(Icons.chevron_right, color: Colors.black38),
            ],
          ),
        ),
      );
    }
    if (node.isGuide) {
      return InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _GuideViewer(node: node),
        )),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
              const Icon(Icons.chevron_right, color: Colors.black38),
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
    _tc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              activeColor: _green,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              side: const BorderSide(color: Colors.black38, width: 2),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => widget.controller.toggle(widget.path, v ?? false),
            ),
            Expanded(child: _TitleSub(title: node.title, subtitle: node.subtitle)),
          ],
        ),
      ),
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
    final pages = widget.node.pages;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        leading: const BackChevron(),
        title: Text(widget.node.title),
      ),
      body: pages.isEmpty
          ? const Center(child: Text('No content yet.', style: TextStyle(color: Colors.black54)))
          : (widget.node.layout == 'scroll' ? _scroll(pages) : _paged(pages)),
    );
  }

  Widget _pageContent(DocPage page) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (page.title != null && page.title!.isNotEmpty)
              Text(page.title!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (page.subtitle != null && page.subtitle!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(page.subtitle!, style: const TextStyle(color: Colors.black54, fontSize: 13)),
              ),
            const SizedBox(height: 12),
            ...buildBlocks(page.blocks),
          ],
        ),
      );

  Widget _scroll(List<DocPage> pages) => ListView.separated(
        itemCount: pages.length,
        separatorBuilder: (context, index) =>
            const Divider(height: 1, thickness: 6, color: Color(0xFFF2F2F2)),
        itemBuilder: (context, i) => _pageContent(pages[i]),
      );

  Widget _paged(List<DocPage> pages) => Column(
        children: [
          LinearProgressIndicator(
            value: pages.isEmpty ? 0 : (_page + 1) / pages.length,
            minHeight: 3,
            backgroundColor: Colors.black12,
            valueColor: const AlwaysStoppedAnimation(_accent),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              onPageChanged: (i) => setState(() => _page = i),
              itemCount: pages.length,
              itemBuilder: (context, i) => _pageContent(pages[i]),
            ),
          ),
          _StepNav(
            page: _page,
            total: pages.length,
            onPrev: _page > 0
                ? () => _pageCtrl.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
                : null,
            onNext: _page < pages.length - 1
                ? () => _pageCtrl.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut)
                : null,
          ),
        ],
      );
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.isEmpty ? 'Untitled' : title,
            style: TextStyle(
                color: Colors.black,
                fontSize: big ? 18 : 16,
                fontWeight: big ? FontWeight.w600 : FontWeight.normal)),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!, style: const TextStyle(color: Colors.black54, fontSize: 12, height: 1.3)),
          ),
      ],
    );
  }
}

class _PercentCard extends StatelessWidget {
  final String text;
  final double value;
  const _PercentCard({required this.text, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: const TextStyle(color: Colors.black, fontSize: 13)),
            const SizedBox(height: 10),
            _ProgressBar(value: value),
          ],
        ),
      );
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
          backgroundColor: Colors.black12,
          valueColor: const AlwaysStoppedAnimation(_bar),
        ),
      );
}

Widget _navPill(IconData icon, String label, VoidCallback? onTap, {bool iconLeading = true}) {
  final enabled = onTap != null;
  final color = enabled ? _accent : Colors.black26;
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
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.black12)),
          ),
          child: Row(
            children: [
              _navPill(Icons.chevron_left, 'Prev', onPrev),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Step ${page + 1} of $total',
                        style: const TextStyle(fontSize: 13, color: Colors.black54)),
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
                                shape: BoxShape.circle, color: i == page ? _accent : Colors.black26),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _navPill(Icons.chevron_right, 'Next', onNext, iconLeading: false),
            ],
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  final Future<void> Function() onRefresh;
  const _Empty({required this.onRefresh});

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            Icon(Icons.inbox_outlined, size: 48, color: Colors.black26),
            SizedBox(height: 12),
            Center(child: Text("It's empty here", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            SizedBox(height: 6),
            Center(
              child: Text('Pull down to refresh.',
                  style: TextStyle(color: Colors.black54, fontSize: 13)),
            ),
          ],
        ),
      );
}
