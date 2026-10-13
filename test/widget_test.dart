import 'dart:io';
import 'dart:ui' as ui;
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/main.dart';
import 'package:chagok/ui/entry_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = File('C:/Windows/Fonts/malgun.ttf');
    if (font.existsSync()) {
      await (FontLoader('Malgun Gothic')
            ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b))))
          .load();
    }
  });
  late LedgerStore store;
  late AppController app;
  setUp(() {
    store = LedgerStore.memory();
    app = AppController(store, '.');
    app.initialize();
    app.service.saveAccount(id: 'bank', name: '생활비 통장', opening: 3200000);
    app.service.saveAccount(
      id: 'saving',
      name: '정기 적금',
      kind: 'savings',
      opening: 1500000,
      liquid: false,
    );
    app.service.createDebt(
      person: '테스트 친구',
      direction: 'lent',
      amount: 100000,
      on: today(),
    );
    app.service.saveEntry(
      app.service.makeEntry(
        type: 'expense',
        amount: 90000,
        account: 'bank',
        on: today(),
        allocations: [app.service.allocation(30000, '식비', subcategory: '외식')],
        shares: [
          {'id': 'friend', 'person': '테스트 친구', 'amount': 60000},
        ],
      ),
    );
    app.service.saveRule({
      'type': 'transfer',
      'amount': 500000,
      'account': 'bank',
      'destination': 'saving',
      'start': '2099-01-31',
      'effective': '2099-01-31',
      'cycle': 'monthly',
      'anchor_day': 31,
      'anchor_month': 1,
      'memo': '미래 적금',
    });
    for (final (amount, category, sub) in [
      (58000, '식비', '외식'),
      (29000, '교통', '대중교통'),
      (16000, '여가', '구독'),
    ]) {
      app.service.saveEntry(
        app.service.makeEntry(
          type: 'expense',
          amount: amount,
          account: 'bank',
          on: today(),
          memo: '화면 검증용 예시',
          allocations: [
            app.service.allocation(amount, category, subcategory: sub),
          ],
        ),
      );
    }
  });
  tearDown(() {
    app.dispose();
    store.close();
  });
  for (final size in [
    const Size(344, 820),
    const Size(690, 820),
    const Size(1280, 800),
  ]) {
    testWidgets('responsive home and all tabs at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ChagokApp(app: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('전체 보유 금액'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (size.width == 1280) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/screenshots').create(recursive: true);
          await File(
            'build/screenshots/home-windows.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      for (final label in ['내역', '계좌', '리포트', '더보기']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      for (final label in ['정산', '빚 관리', '정기 내역', '카테고리', '설정', '충돌 해결']) {
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'draft survives fold resize and save stores selected category plus memo',
    (tester) async {
      tester.view.physicalSize = const Size(690, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ChagokApp(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.text('내역 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '12000');
      await tester.tap(find.text('대분류').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('식비').last);
      await tester.pumpAndSettle();
      final memo = find.widgetWithText(TextField, '메모 (선택)');
      await tester.ensureVisible(memo);
      await tester.enterText(memo, '점심');
      tester.view.physicalSize = const Size(344, 820);
      await tester.pumpAndSettle();
      expect(find.text('12000'), findsOneWidget);
      expect(find.text('점심'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('저장'));
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditor), findsNothing);
      expect(
        store.all('entry').where((e) => e['memo'] == '점심').single['amount'],
        12000,
      );
      expect(store.local('entry_draft'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
