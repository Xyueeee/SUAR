import 'package:flutter/material.dart';

/// A stemless `<` back button (Icons.chevron_left) — the app's standard back
/// affordance, used as the AppBar `leading` so every screen matches the custom
/// dark-header screens instead of the default Material arrow (`←`).
class BackChevron extends StatelessWidget {
  const BackChevron({super.key, this.color = Colors.black});

  final Color color;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(Icons.chevron_left, color: color),
        onPressed: () => Navigator.maybePop(context),
      );
}
