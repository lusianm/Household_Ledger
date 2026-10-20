import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/ui/monthly_flow_chart.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/NotoSansKR.ttf'))).load();
  });
  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'monthly comparison handles zero and negative values at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(scaffoldBackgroundColor: Colors.white),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: MonthlyFlowChart([
                    (month: 6, income: 0, expense: 0),
                    (month: 7, income: 3500000, expense: 2300000),
                    (month: 8, income: 3500000, expense: 4200000),
                    (month: 9, income: 3400000, expense: 2100000),
                    (month: 10, income: 1500000, expense: -100000),
                  ]),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('0원'), findsNWidgets(2));
        expect(find.text('-100,000원'), findsOneWidget);
        expect(find.text('3,500,000원'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        if (width == 1100) {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('build/screenshots').create(recursive: true);
            await File(
              'build/screenshots/monthly-flow-example.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
