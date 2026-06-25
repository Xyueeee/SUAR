/// Unified content model shared by survival / first_aid / preparation / prep.
/// One Doc = a tree of nodes. A `section` groups children (and can show/tally a
/// %). A leaf is either a checklist field (`check`/`text`/`number`, contributes
/// to %) or a `guide` (pages of blocks, no %). Built + rendered by ONE editor /
/// renderer; categories only separate them for organisation.
///
/// Pure parsing + roll-up (no Flutter) so it stays unit-testable. Blocks/runs
/// are reused from content_models.
library;

import 'dart:convert';

import 'content_models.dart' show Block;

class DocPage {
  final String? title;
  final String? subtitle;
  final List<Block> blocks;
  const DocPage({this.title, this.subtitle, required this.blocks});

  factory DocPage.fromJson(Map<String, dynamic> j) => DocPage(
        title: j['title']?.toString(),
        subtitle: j['subtitle']?.toString(),
        blocks: (j['blocks'] is List)
            ? (j['blocks'] as List)
                .whereType<Map>()
                .map((b) => Block.fromJson(b.cast<String, dynamic>()))
                .toList()
            : const [],
      );
}

class DocNode {
  final String title;
  final String? subtitle;
  final String kind; // section | check | text | number | guide
  final num weight;
  final bool usePercent; // section: show + tally a % at this level
  final List<DocNode> children; // section
  final String layout; // guide: steps | scroll
  final List<DocPage> pages; // guide

  const DocNode({
    required this.title,
    this.subtitle,
    required this.kind,
    this.weight = 1,
    this.usePercent = false,
    this.children = const [],
    this.layout = 'steps',
    this.pages = const [],
  });

  bool get isSection => kind == 'section';
  bool get isGuide => kind == 'guide';
  bool get isField => kind == 'check' || kind == 'text' || kind == 'number';

  factory DocNode.fromJson(Map<String, dynamic> j) {
    final kind = (j['kind'] ?? 'section').toString();
    return DocNode(
      title: (j['title'] ?? '').toString(),
      subtitle: (j['subtitle'])?.toString(),
      kind: kind,
      weight: (j['weight'] is num) ? j['weight'] as num : 1,
      usePercent: j['usePercent'] == true,
      children: kind == 'section' ? listFrom(j['children']) : const [],
      layout: j['layout']?.toString() == 'scroll' ? 'scroll' : 'steps',
      pages: (kind == 'guide' && j['pages'] is List)
          ? (j['pages'] as List)
              .whereType<Map>()
              .map((p) => DocPage.fromJson(p.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }

  static List<DocNode> listFrom(dynamic v) => (v is List)
      ? v.whereType<Map>().map((m) => DocNode.fromJson(m.cast<String, dynamic>())).toList()
      : const [];
}

class Doc {
  final String docid;
  final String category; // survival | first_aid | preparation | prep
  final String title;
  final int version;
  final bool usePercent; // doc-level % card
  final String percentText; // {p} replaced with the rounded percent
  final List<DocNode> nodes;
  final String structureJson;
  final String updatedAt;

  const Doc({
    required this.docid,
    required this.category,
    required this.title,
    required this.version,
    required this.usePercent,
    required this.percentText,
    required this.nodes,
    required this.structureJson,
    required this.updatedAt,
  });

  factory Doc.fromRow({
    required String docid,
    required String category,
    required String title,
    required int version,
    required String updatedAt,
    required dynamic structure,
  }) {
    dynamic d = structure;
    if (structure is String) {
      try {
        d = jsonDecode(structure);
      } catch (_) {
        d = const {};
      }
    }
    final m = d is Map ? d : const {};
    return Doc(
      docid: docid,
      category: category,
      title: title,
      version: version,
      updatedAt: updatedAt,
      usePercent: m['usePercent'] == true,
      percentText: (m['percentText'] ?? 'You are {p}% prepared for an emergency:').toString(),
      nodes: DocNode.listFrom(m['nodes']),
      structureJson: structure is String ? structure : jsonEncode(structure),
    );
  }
}

// --------------------------------------------------------------------------- //
// Roll-up. `done` = set of completed field-leaf paths (path = positional, e.g. //
// "0.1.2"). Only field leaves count; guides don't. A section's fraction is the //
// weighted average of its counting children.                                   //
// --------------------------------------------------------------------------- //
class DocRollup {
  final Set<String> done;
  const DocRollup(this.done);

  /// Completed fraction (0..1) of a node's countable descendants, or null if the
  /// node has nothing that counts (pure guide / empty).
  double? frac(DocNode n, String path) {
    if (n.isField) return done.contains(path) ? 1.0 : 0.0;
    if (n.isGuide) return null;
    return _childrenFrac(n.children, path);
  }

  double? _childrenFrac(List<DocNode> kids, String path) {
    double wsum = 0, acc = 0;
    for (var i = 0; i < kids.length; i++) {
      final p = path.isEmpty ? '$i' : '$path.$i';
      final f = frac(kids[i], p);
      if (f == null) continue;
      final w = kids[i].weight.toDouble();
      final ww = w > 0 ? w : 0;
      wsum += ww;
      acc += ww * f;
    }
    if (wsum <= 0) return null;
    return acc / wsum;
  }

  /// 0..100 overall for the whole doc.
  double overallPercent(List<DocNode> nodes) => (_childrenFrac(nodes, '') ?? 0) * 100;

  /// 0..100 for a single node (its internal completion).
  double nodePercent(DocNode n, String path) => (frac(n, path) ?? 0) * 100;

  /// Whether a node contributes to any %.
  bool counts(DocNode n, String path) => frac(n, path) != null;

  /// First [max] incomplete field leaves, labelled with their top-level section
  /// for context, e.g. "Emergency Supply Pack › Drinking water".
  List<String> incompleteTitles(List<DocNode> nodes, int max) {
    final out = <String>[];
    void walk(List<DocNode> ns, String path, String group) {
      for (var i = 0; i < ns.length && out.length < max; i++) {
        final p = path.isEmpty ? '$i' : '$path.$i';
        final n = ns[i];
        if (n.isSection) {
          walk(n.children, p, group.isEmpty ? n.title : group);
        } else if (n.isField && !done.contains(p)) {
          final leaf = n.title.isEmpty ? 'Untitled' : n.title;
          out.add(group.isEmpty ? leaf : '$group › $leaf');
        }
      }
    }

    walk(nodes, '', '');
    return out;
  }

  /// Incomplete field leaves grouped under their top-level section, in order,
  /// capped at [max] total items: [(sectionTitle, [itemTitle, ...]), ...].
  List<MapEntry<String, List<String>>> incompleteGrouped(List<DocNode> nodes, int max) {
    final map = <String, List<String>>{};
    final order = <String>[];
    var count = 0;
    void walk(List<DocNode> ns, String path, String group) {
      for (var i = 0; i < ns.length && count < max; i++) {
        final p = path.isEmpty ? '$i' : '$path.$i';
        final n = ns[i];
        if (n.isSection) {
          walk(n.children, p, group.isEmpty ? n.title : group);
        } else if (n.isField && !done.contains(p)) {
          final g = group.isEmpty ? 'General' : group;
          if (!map.containsKey(g)) { map[g] = []; order.add(g); }
          map[g]!.add(n.title.isEmpty ? 'Untitled' : n.title);
          count++;
        }
      }
    }

    walk(nodes, '', '');
    return [for (final g in order) MapEntry(g, map[g]!)];
  }

  /// Total number of incomplete field leaves (to know if a capped list omitted some).
  int incompleteCount(List<DocNode> nodes) {
    var c = 0;
    void walk(List<DocNode> ns, String path) {
      for (var i = 0; i < ns.length; i++) {
        final p = path.isEmpty ? '$i' : '$path.$i';
        final n = ns[i];
        if (n.isSection) {
          walk(n.children, p);
        } else if (n.isField && !done.contains(p)) {
          c++;
        }
      }
    }

    walk(nodes, '');
    return c;
  }
}
