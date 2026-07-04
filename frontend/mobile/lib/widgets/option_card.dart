import 'package:flutter/material.dart';

import '../theme.dart';

/// Generic selectable settings option: icon/label/description + a custom
/// preview widget, with a checkmark when selected. Shared by the Appearance
/// and Activity Log settings pages, and reused verbatim in onboarding.
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected
              ? kAccentPale.withValues(alpha: 0.15)
              : (dark ? kPanelDark : cs.onSurface.withValues(alpha: 0.05)),
          border: Border.all(
            color: selected
                ? kAccentInk.withValues(alpha: 0.7)
                : cs.onSurface.withValues(alpha: 0.18),
            width: selected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            preview,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon,
                          size: 18,
                          color: selected
                              ? kAccentInk
                              : cs.onSurface.withValues(alpha: 0.7)),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                          color: selected ? kAccentInk : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.check_circle,
                color: selected ? kAccentInk : Colors.transparent, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Mini phone-frame mockup showing the colour palette for each ThemeMode.
class ThemePreview extends StatelessWidget {
  const ThemePreview({super.key, required this.themeMode});
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    final systemDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final previewDark = switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => systemDark,
    };

    final bg = previewDark ? const Color(0xFF111111) : const Color(0xFFF5F5F5);
    final panel = previewDark ? kPanelDark : const Color(0xFFE0E0E0);
    final text = previewDark ? Colors.white70 : Colors.black54;

    return Container(
      width: 52,
      height: 80,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: [
          Container(height: 6, color: panel),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: kAccentInk.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              height: 10,
              width: 28,
              decoration: BoxDecoration(
                color: text.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
