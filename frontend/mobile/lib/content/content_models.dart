/// Data models for admin-authored content consumed by the app, fully offline:
///   - Guides (survival / first_aid / preparation) rendered from a block-JSON
///     document (see docs/superpowers/specs — replaces the old Quill HTML).
///   - Prep plans (nested weighted checklist) with the % roll-up that must match
///     the web preview (frontend/web/js/views/prep.js computePercents).
///
/// Everything here is pure parsing + math (no Flutter) so the roll-up is unit
/// testable. Colour parsing returns an int ARGB to keep this file widget-free;
/// the renderer turns it into a Color.
library;

import 'dart:convert';

// --------------------------------------------------------------------------- //
// Inline runs + blocks (guide body)                                           //
// --------------------------------------------------------------------------- //

/// A span of text with optional inline formatting. Maps 1:1 to a TextSpan.
class Run {
  final String text;
  final bool bold, italic, underline, strike;

  /// ARGB int, or null for default. (#RRGGBB in JSON → 0xFFRRGGBB here.)
  final int? colorArgb;

  const Run(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.colorArgb,
  });

  factory Run.fromJson(Map<String, dynamic> j) => Run(
        (j['text'] ?? '').toString(),
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strike: j['strike'] == true,
        colorArgb: _parseColor(j['color']),
      );
}

List<Run> _runs(dynamic v) => (v is List)
    ? v.whereType<Map>().map((m) => Run.fromJson(m.cast<String, dynamic>())).toList()
    : const [];

int? _parseColor(dynamic v) {
  if (v is! String) return null;
  var s = v.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s'; // assume opaque
  if (s.length != 8) return null;
  return int.tryParse(s, radix: 16);
}

/// A content block. Unknown block types parse to [UnknownBlock] (skipped on
/// render) so newer admin output never crashes an older app.
sealed class Block {
  const Block();

  factory Block.fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'heading':
        final lvl = (j['level'] as num?)?.toInt() ?? 2;
        return HeadingBlock(level: lvl < 1 ? 1 : (lvl > 3 ? 3 : lvl), runs: _runs(j['runs']));
      case 'paragraph':
        return ParagraphBlock(_runs(j['runs']));
      case 'bullets':
        final items = (j['items'] is List)
            ? (j['items'] as List).map(_runs).toList()
            : <List<Run>>[];
        return BulletsBlock(ordered: j['ordered'] == true, items: items);
      case 'image':
        return ImageBlock(url: (j['url'] ?? '').toString(), caption: (j['caption'])?.toString());
      case 'divider':
        return const DividerBlock();
      default:
        return const UnknownBlock();
    }
  }
}

class HeadingBlock extends Block {
  final int level;
  final List<Run> runs;
  const HeadingBlock({required this.level, required this.runs});
}

class ParagraphBlock extends Block {
  final List<Run> runs;
  const ParagraphBlock(this.runs);
}

class BulletsBlock extends Block {
  final bool ordered;
  final List<List<Run>> items;
  const BulletsBlock({required this.ordered, required this.items});
}

class ImageBlock extends Block {
  final String url;
  final String? caption;
  const ImageBlock({required this.url, this.caption});
}

class DividerBlock extends Block {
  const DividerBlock();
}

class UnknownBlock extends Block {
  const UnknownBlock();
}

/// One step / section of a guide.
class GuidePage {
  final String? title;
  final List<Block> blocks;
  const GuidePage({this.title, required this.blocks});

  factory GuidePage.fromJson(Map<String, dynamic> j) => GuidePage(
        title: (j['title'])?.toString(),
        blocks: (j['blocks'] is List)
            ? (j['blocks'] as List)
                .whereType<Map>()
                .map((b) => Block.fromJson(b.cast<String, dynamic>()))
                .toList()
            : const [],
      );
}

/// A guide topic (one `appcontent` row). [bodyJson] is the raw body string kept
/// for caching verbatim; [pages]/[layout] are the parsed view of it.
class Guide {
  final String contentid;
  final String category; // survival | first_aid | preparation
  final String title;

  /// Section grouping within a category, e.g. "Basic First Aid" or a nested
  /// path "Basic First Aid/Wounds" (split on '/'). Empty = ungrouped.
  final String section;
  final int version;
  final String layout; // paged | list
  final List<GuidePage> pages;
  final String bodyJson;
  final String updatedAt;

  const Guide({
    required this.contentid,
    required this.category,
    required this.title,
    required this.section,
    required this.version,
    required this.layout,
    required this.pages,
    required this.bodyJson,
    required this.updatedAt,
  });

  /// Section split into its path segments (for nested grouping). Empty list when
  /// no section is set.
  List<String> get sectionPath =>
      section.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  /// Builds from a row map (backend JSON or a cached SQLite row). [body] may be
  /// a JSON string (current) or already-decoded; legacy HTML degrades to text.
  factory Guide.fromRow({
    required String contentid,
    required String category,
    required String title,
    String section = '',
    required int version,
    required String updatedAt,
    required dynamic body,
  }) {
    final parsed = _parseBody(body);
    return Guide(
      contentid: contentid,
      category: category,
      title: title,
      section: section,
      version: version,
      layout: parsed.layout,
      pages: parsed.pages,
      bodyJson: body is String ? body : jsonEncode(body),
      updatedAt: updatedAt,
    );
  }

  static ({String layout, List<GuidePage> pages}) _parseBody(dynamic raw) {
    dynamic decoded = raw;
    if (raw is String) {
      final t = raw.trim();
      if (t.isEmpty) return (layout: 'paged', pages: const []);
      try {
        decoded = jsonDecode(t);
      } catch (_) {
        // Legacy Quill HTML / plain text — strip tags, show as one page.
        return (
          layout: 'list',
          pages: [
            GuidePage(blocks: [ParagraphBlock([Run(_stripHtml(t))])])
          ]
        );
      }
    }
    if (decoded is Map && decoded['pages'] is List) {
      final layout = decoded['layout']?.toString() == 'list' ? 'list' : 'paged';
      final pages = (decoded['pages'] as List)
          .whereType<Map>()
          .map((p) => GuidePage.fromJson(p.cast<String, dynamic>()))
          .toList();
      return (layout: layout, pages: pages);
    }
    return (layout: 'paged', pages: const []);
  }
}

String _stripHtml(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

// --------------------------------------------------------------------------- //
// Prep plan (nested weighted checklist)                                        //
// --------------------------------------------------------------------------- //

class PrepNode {
  final String title;
  final bool isGroup;
  final num weight;
  final String fieldType; // checkbox | text | number (items only)
  final List<PrepNode> children;

  const PrepNode({
    required this.title,
    required this.isGroup,
    required this.weight,
    this.fieldType = 'checkbox',
    this.children = const [],
  });

  factory PrepNode.fromJson(Map<String, dynamic> j) {
    final isGroup = j['type'] == 'group';
    return PrepNode(
      title: (j['title'] ?? '').toString(),
      isGroup: isGroup,
      weight: (j['weight'] is num) ? j['weight'] as num : 1,
      fieldType: (j['fieldType'] ?? 'checkbox').toString(),
      children: isGroup ? PrepNode.listFrom(j['children']) : const [],
    );
  }

  static List<PrepNode> listFrom(dynamic v) => (v is List)
      ? v
          .whereType<Map>()
          .map((m) => PrepNode.fromJson(m.cast<String, dynamic>()))
          .toList()
      : const [];
}

class PrepPlan {
  final String prepplanid;
  final String title;
  final int version;
  final List<PrepNode> nodes;
  final String structureJson;
  final String updatedAt;

  const PrepPlan({
    required this.prepplanid,
    required this.title,
    required this.version,
    required this.nodes,
    required this.structureJson,
    required this.updatedAt,
  });

  factory PrepPlan.fromRow({
    required String prepplanid,
    required String title,
    required int version,
    required String updatedAt,
    required dynamic structure,
  }) {
    dynamic decoded = structure;
    if (structure is String) {
      try {
        decoded = jsonDecode(structure);
      } catch (_) {
        decoded = const [];
      }
    }
    return PrepPlan(
      prepplanid: prepplanid,
      title: title,
      version: version,
      nodes: PrepNode.listFrom(decoded),
      structureJson: structure is String ? structure : jsonEncode(structure),
      updatedAt: updatedAt,
    );
  }
}

// --------------------------------------------------------------------------- //
// Roll-up math (must match web prep.js)                                        //
// --------------------------------------------------------------------------- //
//
// Path addressing: top-level node i has path "i"; its child j has path "i.j".
// `done` is the set of *leaf* paths considered complete (checkbox ticked, or a
// text/number field filled). Only leaves contribute; a group's completion is
// the sum of its completed descendants' shares.

double _w(PrepNode n) {
  final w = n.weight.toDouble();
  return w > 0 ? w : 0;
}

double _completedChildren(
    List<PrepNode> kids, String parentPath, double share, Set<String> done) {
  final sum = kids.fold<double>(0, (a, k) => a + _w(k));
  if (sum <= 0) return 0;
  var acc = 0.0;
  for (var i = 0; i < kids.length; i++) {
    final p = parentPath.isEmpty ? '$i' : '$parentPath.$i';
    final kShare = share * (_w(kids[i]) / sum);
    acc += _completedNode(kids[i], p, kShare, done);
  }
  return acc;
}

double _completedNode(PrepNode n, String path, double share, Set<String> done) {
  if (!n.isGroup) return done.contains(path) ? share : 0;
  return _completedChildren(n.children, path, share, done);
}

/// Overall completion of the whole plan, 0..100.
double planOverallPercent(List<PrepNode> top, Set<String> done) =>
    _completedChildren(top, '', 1.0, done) * 100;

/// A single node's *internal* completion (0..100), independent of its own
/// weight — used for the per-category card % and drill-in row %.
double nodePercent(PrepNode n, String path, Set<String> done) =>
    _completedNode(n, path, 1.0, done) * 100;

/// Titles of the first [max] incomplete leaves, in order — feeds the dashboard
/// "to be improved" list.
List<String> incompleteLeafTitles(List<PrepNode> top, Set<String> done, int max) {
  final out = <String>[];
  void walk(List<PrepNode> nodes, String parentPath) {
    for (var i = 0; i < nodes.length && out.length < max; i++) {
      final p = parentPath.isEmpty ? '$i' : '$parentPath.$i';
      final n = nodes[i];
      if (n.isGroup) {
        walk(n.children, p);
      } else if (!done.contains(p)) {
        out.add(n.title.isEmpty ? 'Untitled item' : n.title);
      }
    }
  }

  walk(top, '');
  return out;
}
