import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/main.dart';
import 'package:chagok/ui/settlement_editor.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/NotoSansKR.ttf'))).load();
  });
  for (final width in [344.0, 690.0, 1280.0]) {
    testWidgets('select transactions and save computed settlement at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LedgerStore.memory(), key = GlobalKey();
      final app = AppController(store, '.');
      app.initialize();
      addTearDown(() {
        app.dispose();
        store.close();
      });
      final account = app.service.saveAccount(
        name: '생활',
        opened: '2026-01-01',
        opening: 100000,
      );
      for (final (type, amount) in [('expense', 10000), ('income', 12000)]) {
        app.service.saveEntry(
          app.service.makeEntry(
            type: type,
            amount: amount,
            account: account,
            on: '2026-07-01',
            memo: type == 'expense' ? '공동 구매' : '구매 비용 받음',
            allocations: [app.service.allocation(amount, '기타')],
          ),
        );
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ChagokApp(app: app).theme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSettlement(context, app),
                  child: const Text('정산 만들기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('정산 만들기'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '정산 이름'),
        '공동 구매 정산',
      );
      final choose = find.text('연결 내역 선택 · 0건');
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('선택 적용'));
      await tester.pumpAndSettle();
      expect(find.text('자동 계산 · 순수입 2,000원'), findsOneWidget);
      expect(find.text('통계 기준일 2026-07-01'), findsOneWidget);
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(store.all('settlement_group').single['members'], hasLength(2));
      expect(store.flow('2026-07', 'income'), 2000);
      expect(store.flow('2026-07', 'expense'), 0);
      expect(store.balance(account), 102000);
      expect(tester.takeException(), isNull);
      // Persisted checklist is independent of transaction selection and totals.
      final group = store.all('settlement_group').single;
      group['claims'] = [
        {
          'id': 'friend',
          'person': '친구',
          'amount': 3000,
          'memo': '',
          'received': false,
        },
      ];
      store.save('settlement_group', group);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ChagokApp(app: app).theme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showSettlement(context, app, id: group['id'] as String),
                  child: const Text('정산 열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('정산 열기'));
      await tester.pumpAndSettle();
      final claim = find.byType(CheckboxListTile);
      await tester.ensureVisible(claim);
      await tester.tap(claim);
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(
        rows(store.all('settlement_group').single['claims']).single['received'],
        true,
      );
      expect(store.balance(account), 102000);
      expect(store.flow('2026-07', 'income'), 2000);
      await tester.tap(find.text('정산 열기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Capture the full overlay so responsive layout can be inspected locally.
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('outputs/settlement-ui-${width.toInt()}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
