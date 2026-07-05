/// Inline runs + blocks for admin-authored content (block-JSON), fully offline.
/// Consumed by block_renderer.dart and doc_models.dart — the doc tree that
/// carries these blocks lives in doc_models.dart (the unified appdoc model).
///
/// Pure parsing (no Flutter) so it stays unit-testable. Colour parsing returns
/// an int ARGB to keep this file widget-free; the renderer turns it into a
/// Color.
library;

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
