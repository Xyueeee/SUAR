import 'package:flutter/material.dart';

/// A stemless `<` back button (Icons.chevron_left) — the app's standard back
/// affordance, used as the AppBar `leading` so every screen matches the custom
/// dark-header screens instead of the default Material arrow (`←`).
///
/// When [color] is omitted the icon colour comes from the active
/// [ColorScheme.onSurface], making it theme-aware (works in both light and
/// dark themes without an explicit override).
class BackChevron extends StatelessWidget {
  const BackChevron({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(
          Icons.chevron_left,
          color: color ?? Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: () => Navigator.maybePop(context),
      );
}