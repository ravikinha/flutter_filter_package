import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_filter_engine/main.dart';

void main() {
  testWidgets('App boots and shows scaffold', (WidgetTester tester) async {
    await tester.pumpWidget(const CameraFilterApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
