import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import '../theme.dart' show kPanelDark, kAccentInk, kAccentPale;

const double _handleSize = 14;
const double _minBoxSize = 44;

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

/// Square photo cropper rendered as a normal app page (AppBar + theme colors)
/// instead of a native Activity, so it looks like every other screen.
///
/// Same interaction model as the map area-picker in
/// [RegionDownloadScreen] (drag the box to move it, drag a corner to resize)
/// just restyled for a photo instead of a map: the image is static
/// (BoxFit.contain, no pinch/zoom), and a square selection box sits on top,
/// dimmed outside via a scrim-with-a-hole so it's clear what gets left out.
class PhotoCropScreen extends StatefulWidget {
  const PhotoCropScreen({super.key, required this.imagePath});
  final String imagePath;

  @override
  State<PhotoCropScreen> createState() => _PhotoCropScreenState();
}

class _PhotoCropScreenState extends State<PhotoCropScreen> {
  final _boundaryKey = GlobalKey();
  double? _imgW;
  double? _imgH;
  Rect? _selectionRect;
  bool _initialized = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width.toDouble();
    final h = frame.image.height.toDouble();
    frame.image.dispose();
    if (!mounted) return;
    setState(() {
      _imgW = w;
      _imgH = h;
    });
  }

  /// The rect the image actually renders into within [stageSize] under
  /// BoxFit.contain — the selection box is clamped to stay inside this.
  Rect _imageRect(Size stageSize) {
    final scaleW = stageSize.width / _imgW!;
    final scaleH = stageSize.height / _imgH!;
    final scale = scaleW < scaleH ? scaleW : scaleH;
    final w = _imgW! * scale;
    final h = _imgH! * scale;
    return Rect.fromLTWH((stageSize.width - w) / 2, (stageSize.height - h) / 2, w, h);
  }

  void _initSelectionRect(Rect imageRect) {
    if (_initialized) return;
    final size = (imageRect.width < imageRect.height ? imageRect.width : imageRect.height) * 0.85;
    _selectionRect = Rect.fromCenter(center: imageRect.center, width: size, height: size);
    _initialized = true;
  }

  void _onBodyDrag(DragUpdateDetails details, Rect imageRect) {
    final rect = _selectionRect!;
    final newLeft = (rect.left + details.delta.dx).clamp(imageRect.left, imageRect.right - rect.width);
    final newTop = (rect.top + details.delta.dy).clamp(imageRect.top, imageRect.bottom - rect.height);
    setState(() => _selectionRect = Rect.fromLTWH(newLeft, newTop, rect.width, rect.height));
  }

  /// Every corner drag keeps the opposite corner fixed and forces width ==
  /// height (locked square), clamped to stay within [imageRect].
  void _onCornerDrag(_Corner corner, DragUpdateDetails details, Rect imageRect) {
    final rect = _selectionRect!;
    final dx = details.delta.dx;
    final dy = details.delta.dy;
    Rect next;
    switch (corner) {
      case _Corner.topLeft:
        final anchor = rect.bottomRight;
        final maxSize = (anchor.dx - imageRect.left < anchor.dy - imageRect.top)
            ? anchor.dx - imageRect.left
            : anchor.dy - imageRect.top;
        if (maxSize < _minBoxSize) return;
        final w = anchor.dx - (rect.left + dx);
        final h = anchor.dy - (rect.top + dy);
        final size = (w < h ? w : h).clamp(_minBoxSize, maxSize);
        next = Rect.fromLTRB(anchor.dx - size, anchor.dy - size, anchor.dx, anchor.dy);
      case _Corner.topRight:
        final anchor = rect.bottomLeft;
        final maxSize = (imageRect.right - anchor.dx < anchor.dy - imageRect.top)
            ? imageRect.right - anchor.dx
            : anchor.dy - imageRect.top;
        if (maxSize < _minBoxSize) return;
        final w = (rect.right + dx) - anchor.dx;
        final h = anchor.dy - (rect.top + dy);
        final size = (w < h ? w : h).clamp(_minBoxSize, maxSize);
        next = Rect.fromLTRB(anchor.dx, anchor.dy - size, anchor.dx + size, anchor.dy);
      case _Corner.bottomLeft:
        final anchor = rect.topRight;
        final maxSize = (anchor.dx - imageRect.left < imageRect.bottom - anchor.dy)
            ? anchor.dx - imageRect.left
            : imageRect.bottom - anchor.dy;
        if (maxSize < _minBoxSize) return;
        final w = anchor.dx - (rect.left + dx);
        final h = (rect.bottom + dy) - anchor.dy;
        final size = (w < h ? w : h).clamp(_minBoxSize, maxSize);
        next = Rect.fromLTRB(anchor.dx - size, anchor.dy, anchor.dx, anchor.dy + size);
      case _Corner.bottomRight:
        final anchor = rect.topLeft;
        final maxSize = (imageRect.right - anchor.dx < imageRect.bottom - anchor.dy)
            ? imageRect.right - anchor.dx
            : imageRect.bottom - anchor.dy;
        if (maxSize < _minBoxSize) return;
        final w = (rect.right + dx) - anchor.dx;
        final h = (rect.bottom + dy) - anchor.dy;
        final size = (w < h ? w : h).clamp(_minBoxSize, maxSize);
        next = Rect.fromLTRB(anchor.dx, anchor.dy, anchor.dx + size, anchor.dy + size);
    }
    setState(() => _selectionRect = next);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final stageImage = await boundary.toImage(pixelRatio: dpr);

    final rect = _selectionRect!;
    final src = Rect.fromLTWH(rect.left * dpr, rect.top * dpr, rect.width * dpr, rect.height * dpr);
    final outSize = (rect.width * dpr).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(stageImage, src, Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble()), Paint());
    final croppedImage = await recorder.endRecording().toImage(outSize, outSize);
    stageImage.dispose();

    final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    croppedImage.dispose();
    final dir = p.dirname(widget.imagePath);
    final outPath = p.join(dir, 'cropped_${DateTime.now().millisecondsSinceEpoch}.png');
    await File(outPath).writeAsBytes(byteData!.buffer.asUint8List());
    if (mounted) Navigator.of(context).pop(outPath);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ready = _imgW != null && _imgH != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Crop Photo'),
        actions: [
          TextButton(
            onPressed: ready && !_saving ? _save : null,
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Container(
              color: dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.07),
              child: Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final stageSize = constraints.biggest;
                        final imageRect = _imageRect(stageSize);
                        _initSelectionRect(imageRect);
                        final rect = _selectionRect!;
                        return Stack(
                          children: [
                            RepaintBoundary(
                              key: _boundaryKey,
                              child: SizedBox(
                                width: stageSize.width,
                                height: stageSize.height,
                                child: Image.file(File(widget.imagePath), fit: BoxFit.contain),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(size: stageSize, painter: _ScrimPainter(hole: rect)),
                            ),
                            // Box body — drag anywhere inside (away from a handle) to move it.
                            Positioned(
                              left: rect.left,
                              top: rect.top,
                              width: rect.width,
                              height: rect.height,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (d) => _onBodyDrag(d, imageRect),
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: kAccentPale, width: 2),
                                  ),
                                ),
                              ),
                            ),
                            for (final corner in _Corner.values)
                              _buildHandle(corner, rect, imageRect),
                          ],
                        );
                      },
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 56,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Drag inside the box to move it, or a corner to resize.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.45), fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildHandle(_Corner corner, Rect rect, Rect imageRect) {
    final cx = corner == _Corner.topLeft || corner == _Corner.bottomLeft ? rect.left : rect.right;
    final cy = corner == _Corner.topLeft || corner == _Corner.topRight ? rect.top : rect.bottom;
    const hitSize = _handleSize + 18;
    return Positioned(
      left: cx - hitSize / 2,
      top: cy - hitSize / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _onCornerDrag(corner, d, imageRect),
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: Container(
              width: _handleSize,
              height: _handleSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: kAccentInk, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dims everything in [size] except a punched-out [hole] rect, so the area
/// outside the selection still shows through (half-transparent), matching
/// standard crop-tool UX. Same scrim color in light and dark mode since it's
/// tinting a photo, not a UI surface.
class _ScrimPainter extends CustomPainter {
  _ScrimPainter({required this.hole});
  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(hole)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter oldDelegate) => oldDelegate.hole != hole;
}
