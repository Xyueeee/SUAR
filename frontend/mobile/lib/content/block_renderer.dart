/// Renders a guide's blocks into native Flutter widgets — no WebView. The runs
/// model maps straight onto TextSpan, so what the admin authored renders
/// faithfully and works fully offline. Images are cached to disk on first view.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import 'content_models.dart';

const Color _ink = Color(0xFF1A1A1A);

/// Builds the vertical list of widgets for one page's blocks.
List<Widget> buildBlocks(List<Block> blocks) {
  final out = <Widget>[];
  for (final b in blocks) {
    final w = _blockWidget(b);
    if (w != null) {
      out.add(Padding(padding: const EdgeInsets.only(bottom: 14), child: w));
    }
  }
  return out;
}

Widget? _blockWidget(Block b) {
  switch (b) {
    case HeadingBlock(:final level, :final runs):
      final size = level == 1 ? 22.0 : (level == 2 ? 18.0 : 16.0);
      return Text.rich(
        _spans(runs, TextStyle(fontSize: size, fontWeight: FontWeight.bold, color: _ink, height: 1.3)),
      );
    case ParagraphBlock(:final runs):
      return Text.rich(_spans(runs, const TextStyle(fontSize: 15, color: _ink, height: 1.5)));
    case BulletsBlock(:final ordered, :final items):
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      ordered ? '${i + 1}.' : '•',
                      style: const TextStyle(fontSize: 15, color: _ink, height: 1.5),
                    ),
                  ),
                  Expanded(
                    child: Text.rich(
                      _spans(items[i], const TextStyle(fontSize: 15, color: _ink, height: 1.5)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    case ImageBlock(:final url, :final caption):
      return _GuideImage(url: url, caption: caption);
    case DividerBlock():
      return const Divider(height: 1, color: Colors.black12);
    case UnknownBlock():
      return null;
  }
}

TextSpan _spans(List<Run> runs, TextStyle base) =>
    TextSpan(children: runs.map((r) => _span(r, base)).toList());

TextSpan _span(Run r, TextStyle base) => TextSpan(
      text: r.text,
      style: base.copyWith(
        fontWeight: r.bold ? FontWeight.bold : null,
        fontStyle: r.italic ? FontStyle.italic : null,
        color: r.colorArgb != null ? Color(r.colorArgb!) : base.color,
        decoration: _decoration(r),
      ),
    );

TextDecoration? _decoration(Run r) {
  final d = <TextDecoration>[];
  if (r.underline) d.add(TextDecoration.underline);
  if (r.strike) d.add(TextDecoration.lineThrough);
  return d.isEmpty ? null : TextDecoration.combine(d);
}

// --------------------------------------------------------------------------- //
// Image: asset:// loads from the bundle; http(s) downloads + caches to disk.   //
// --------------------------------------------------------------------------- //

class _GuideImage extends StatefulWidget {
  final String url;
  final String? caption;
  const _GuideImage({required this.url, this.caption});

  @override
  State<_GuideImage> createState() => _GuideImageState();
}

class _GuideImageState extends State<_GuideImage> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = _ContentImageCache.get(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption;
    final Widget image;
    if (widget.url.startsWith('asset://')) {
      image = Image.asset(widget.url.substring(8), fit: BoxFit.cover, errorBuilder: _err);
    } else {
      image = FutureBuilder<File?>(
        future: _file,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return _placeholder();
          final f = snap.data;
          if (f == null) return _placeholder(failed: true);
          return Image.file(f, fit: BoxFit.cover, errorBuilder: _err);
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(aspectRatio: 16 / 10, child: image),
        ),
        if (caption != null && caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(caption,
                style: const TextStyle(fontSize: 12, color: Colors.black54, fontStyle: FontStyle.italic)),
          ),
      ],
    );
  }

  Widget _err(BuildContext context, Object error, StackTrace? stack) =>
      _placeholder(failed: true);

  Widget _placeholder({bool failed = false}) => Container(
        color: Colors.black12,
        alignment: Alignment.center,
        child: Icon(
          failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
          color: Colors.black26,
          size: 36,
        ),
      );
}

class _ContentImageCache {
  /// Returns the cached file for [url], downloading it once if missing. Returns
  /// null on any failure (offline + not yet cached → placeholder).
  static Future<File?> get(String url) async {
    if (!url.startsWith('http')) return null;
    try {
      final dir = Directory(p.join(await getDatabasesPath(), 'content_img'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File(p.join(dir.path, _name(url)));
      if (await f.exists() && await f.length() > 0) return f;

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) return null;
        final bytes = await resp.fold<List<int>>(<int>[], (b, d) => b..addAll(d));
        if (bytes.isEmpty) return null;
        await f.writeAsBytes(bytes, flush: true);
        return f;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  // ponytail: hashCode keying — collisions negligible for a handful of images;
  // swap to a real digest if the library grows large.
  static String _name(String url) {
    final ext = p.extension(Uri.parse(url).path);
    final safeExt = (ext.length >= 2 && ext.length <= 5) ? ext : '.img';
    return '${url.hashCode.toUnsigned(32).toRadixString(16)}$safeExt';
  }
}
