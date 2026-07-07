import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suar_mobile/widgets/mesh_activity_card.dart';

// The mesh activity card's whole anti-jump contract, as a test:
// newest entry renders at the top; when the user is scrolled down, a new
// entry must not move the view AT ALL; when the user is at the top, the
// view follows the newest entry.
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<LogEntry> lines,
    ScrollController controller,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: MeshActivityCard(lines: lines, scrollController: controller),
          ),
        ),
      ),
    );
  }

  testWidgets('new entries do not move a scrolled-down view', (tester) async {
    final controller = ScrollController();
    final lines = [for (var i = 0; i < 30; i++) LogEntry('entry $i')];
    await pump(tester, lines, controller);

    controller.jumpTo(200); // reading older entries, away from the top
    await tester.pump();
    final before = controller.position.pixels;

    // Same-instance in-place mutation + parent rebuild, exactly like the
    // victim/helper screens do.
    lines.add(LogEntry('new entry'));
    await pump(tester, lines, controller);
    await tester.pump();

    expect(controller.position.pixels, before);
    // The new entry extended the scrollable upward instead of shifting it.
    expect(controller.position.minScrollExtent, lessThan(0));
  });

  testWidgets('at top, view follows the newest entry', (tester) async {
    final controller = ScrollController();
    final lines = [for (var i = 0; i < 30; i++) LogEntry('entry $i')];
    await pump(tester, lines, controller);
    expect(controller.position.pixels, 0);

    lines.add(LogEntry('newest'));
    await pump(tester, lines, controller);
    await tester.pump(); // post-frame follow jump + repaint

    expect(controller.position.pixels, controller.position.minScrollExtent);
    expect(find.text('newest'), findsOneWidget);
  });

  testWidgets('newest entry renders above older ones', (tester) async {
    final controller = ScrollController();
    final lines = [LogEntry('older'), LogEntry('newer')];
    await pump(tester, lines, controller);

    final yNewer = tester.getTopLeft(find.text('newer')).dy;
    final yOlder = tester.getTopLeft(find.text('older')).dy;
    expect(yNewer, lessThan(yOlder));
  });
}
