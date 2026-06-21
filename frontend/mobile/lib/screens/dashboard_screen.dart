import 'package:flutter/material.dart';

import 'mode_selection_screen.dart';
import 'settings_screen.dart';

/// Home screen (Figma node 7:269, "4.1.1 SUAR Dashboard"). Only the
/// Emergency Mode card is wired; the rest is static chrome for now.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Reference height is roughly this content's natural size on the
            // Figma frame (800px tall). Larger screens scale fixed-height
            // elements up a little to fill space instead of leaving a gap;
            // smaller screens scale down before falling back to scrolling.
            final scale = (constraints.maxHeight / 800).clamp(0.85, 1.2);
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: 21,
                vertical: 16 * scale,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.local_fire_department,
                            color: Colors.black,
                            size: 28,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'SUAR',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                        icon: const Icon(
                          Icons.settings_outlined,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 24 * scale),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ModeSelectionScreen(),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 121 * scale,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAACAC),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 40,
                            color: Colors.black,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Emergency Mode',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'You are 42% prepared for an emergency:',
                          style: TextStyle(color: Colors.black, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: LinearProgressIndicator(
                            value: 0.42,
                            minHeight: 11,
                            backgroundColor: Colors.white,
                            color: const Color(0xFF62E24B),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'To be improved:',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '• Fill in your medical information.\n'
                          '• Prepare an emergency supply pack:\n'
                          '    • Prepare and pack a First Aid Kit:\n'
                          '      - Elastic Bandage\n'
                          '• And more...',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFA7C7E7),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Text(
                              'Go Improve',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 20,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  Container(
                    width: double.infinity,
                    height: 153 * scale,
                    decoration: BoxDecoration(
                      color: const Color(0xFFA7C7E7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.science_outlined,
                          size: 40,
                          color: Colors.black,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Device Test',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16 * scale),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Survival Tips',
                          style: TextStyle(color: Colors.black, fontSize: 20),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Divider(height: 1, color: Colors.black26),
                        ),
                        Text(
                          'First Aid Tips',
                          style: TextStyle(color: Colors.black, fontSize: 20),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.black12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: const [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home_rounded, color: Colors.black54),
                  Text(
                    'Dashboard',
                    style: TextStyle(color: Colors.black54, fontSize: 14),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.medical_services_outlined, color: Colors.black),
                  Text(
                    'Medical Information',
                    style: TextStyle(color: Colors.black, fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
