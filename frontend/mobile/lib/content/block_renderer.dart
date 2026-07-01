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
/// Pass [textColor] to override the default dark ink — e.g. pass
/// [ColorScheme.onSurface] so text adapts to the active theme.
/// Pass [brightness] so explicitly-black run colours flip to white in dark mode
/// (and vice versa) — the editor only lets admins pick black, not white.
List<Widget> buildBlocks(List<Block> blocks,
    {Color? textColor, Brightness brightness = Brightness.light}) {
  final ink = textColor ?? _ink;
  final out = <Widget>[];
  for (final b in blocks) {
    final w = _blockWidget(b, ink, brightness);
    if (w != null) {
      out.add(Padding(padding: const EdgeInsets.only(bottom: 14), child: w));
    }
  }
  return out;
}

Widget? _blockWidget(Block b, Color ink, Brightness brightness) {
  switch (b) {
    case HeadingBlock(:final level, :final runs):
      final size = level == 1 ? 22.0 : (level == 2 ? 18.0 : 16.0);
      return Text.rich(
        _spans(runs, TextStyle(fontSize: size, fontWeight: FontWeight.bold, color: ink, height: 1.3), brightness),
      );
    case ParagraphBlock(:final runs):
      return Text.rich(_spans(runs, TextStyle(fontSize: 15, color: ink, height: 1.5), brightness));
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
                      style: TextStyle(fontSize: 15, color: ink, height: 1.5),
                    ),
                  ),
                  Expanded(
                    child: Text.rich(
                      _spans(items[i], TextStyle(fontSize: 15, color: ink, height: 1.5), brightness),
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
      return Divider(height: 1, color: ink.withValues(alpha: 0.12));
    case UnknownBlock():
      return null;
  }
}

TextSpan _spans(List<Run> runs, TextStyle base, Brightness brightness) =>
    TextSpan(children: runs.map((r) => _span(r, base, brightness)).toList());

TextSpan _span(Run r, TextStyle base, Brightness brightness) => TextSpan(
      text: r.text,
      style: base.copyWith(
        fontWeight: r.bold ? FontWeight.bold : null,
        fontStyle: r.italic ? FontStyle.italic : null,
        color: _resolveRunColor(r.colorArgb, base.color ?? Colors.black, brightness),
        decoration: _decoration(r),
      ),
    );

/// Flips near-black → white in dark mode (and near-white → black in light mode)
/// so admin-authored black text stays readable without needing a separate
/// white-text option in the editor.
Color _resolveRunColor(int? argb, Color fallback, Brightness brightness) {
  if (argb == null) return fallback;
  final c = Color(argb);
  final lum = c.computeLuminance();
  if (brightness == Brightness.dark && lum < 0.15) return Colors.white;
  if (brightness == Brightness.light && lum > 0.85) return Colors.black;
  return c;
}

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
    final cs = Theme.of(context).colorScheme;
    final caption = widget.caption;
    final Widget image;
    if (widget.url.startsWith('asset://')) {
      image = Image.asset(
        widget.url.substring(8),
        fit: BoxFit.cover,
        errorBuilder: (ctx, e, s) => _placeholder(ctx, failed: true),
      );
    } else {
      image = FutureBuilder<File?>(
        future: _file,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) return _placeholder(ctx);
          final f = snap.data;
          if (f == null) return _placeholder(ctx, failed: true);
          return Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (ctx2, e, s) => _placeholder(ctx2, failed: true),
          );
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
            child: Text(
              caption,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.54),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }

  Widget _placeholder(BuildContext context, {bool failed = false}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.onSurface.withValues(alpha: 0.10),
      alignment: Alignment.center,
      child: Icon(
        failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
        color: cs.onSurface.withValues(alpha: 0.26),
        size: 36,
      ),
    );
  }
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