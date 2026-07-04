import 'dart:async';

import 'package:flutter/material.dart';

/// Single-line text that scrolls right-to-left only when it overflows the
/// available width; otherwise renders as a plain, static [Text]. Used for
/// page titles in tight top bars where a fixed radio pill + help button leave
/// the title a variable remainder.
///
/// Seamless loop: the text is drawn twice with a gap; scrolling by one
/// (text + gap) and jumping back to 0 looks continuous.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.velocity = 32, // pixels per second
    this.gap = 48,
    this.pause = const Duration(seconds: 1),
  });

  final String text;
  final TextStyle? style;
  final double velocity;
  final double gap;
  final Duration pause;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  final ScrollController _sc = ScrollController();
  bool _looping = false;

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  double _textWidth() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final tw = _textWidth();
        if (!c.maxWidth.isFinite || tw <= c.maxWidth) {
          // Fits (or unbounded): no scrolling needed.
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        if (!_looping) {
          _looping = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _loop(tw));
        }
        return ClipRect(
          child: SingleChildScrollView(
            controller: _sc,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              children: [
                Text(widget.text, style: widget.style, maxLines: 1),
                SizedBox(width: widget.gap),
                Text(widget.text, style: widget.style, maxLines: 1),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loop(double textWidth) async {
    final dist = textWidth + widget.gap;
    await Future<void>.delayed(widget.pause);
    while (mounted && _sc.hasClients) {
      final ms = (dist / widget.velocity * 1000).round();
      try {
        await _sc.animateTo(dist,
            duration: Duration(milliseconds: ms), curve: Curves.linear);
      } catch (_) {
        return;
      }
      if (!mounted || !_sc.hasClients) return;
      _sc.jumpTo(0);
      await Future<void>.delayed(widget.pause);
    }
  }
}
