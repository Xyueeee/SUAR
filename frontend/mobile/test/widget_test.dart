import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:suar_mobile/main.dart';

void main() {
  testWidgets('SuarApp builds without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SuarApp(seenOnboarding: true));
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
