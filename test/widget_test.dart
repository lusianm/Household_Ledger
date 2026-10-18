import 'dart:io';
import 'dart:convert';
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
    // Widget tests use Android's default family; render it with the bundled web font.
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/NotoSansKR.ttf'))).load();
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
      await tester.enterText(find.byType(TextField).first, '12a000원');
      await tester.tap(find.text('대분류').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('식비').last);
      await tester.pumpAndSettle();
      final memo = find.widgetWithText(TextField, '메모 (선택)');
      await tester.ensureVisible(memo);
      await tester.enterText(memo, '점심');
      tester.view.physicalSize = const Size(344, 820);
      await tester.pumpAndSettle();
      expect(find.text('12,000'), findsOneWidget);
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
      expect(find.text('전체 내역'), findsOneWidget);
      expect(find.textContaining('${today()} · 점심'), findsOneWidget);
      expect(find.textContaining('방금 저장'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final monthsBack in [0, 1, 12]) {
    testWidgets(
      'new entry calendar opens the viewed month ($monthsBack months back)',
      (tester) async {
        tester.view.physicalSize = const Size(690, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(ChagokApp(app: app));
        await tester.pumpAndSettle();
        await tester.tap(find.text('내역').last);
        await tester.pumpAndSettle();
        for (var i = 0; i < monthsBack; i++) {
          await tester.tap(find.byTooltip('이전 달'));
          await tester.pumpAndSettle();
        }
        if (monthsBack == 1) {
          await tester.tap(find.text('전체 계좌').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('정기 적금').last);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('내역 추가'));
        await tester.pumpAndSettle();
        if (monthsBack == 1) {
          final account = tester.widget<DropdownButtonFormField<String>>(
            find.descendant(
              of: find.byType(EntryEditor),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is DropdownButtonFormField<String> &&
                    w.decoration.labelText == '계좌',
              ),
            ),
          );
          expect(account.initialValue, 'saving');
          await tester.tap(find.text('이동').last);
          await tester.pumpAndSettle();
          expect(jsonDecode(store.local('entry_draft')!)['account'], 'saving');
        }
        final now = date(today());
        final expected = monthsBack == 0
            ? now
            : DateTime.utc(now.year, now.month - monthsBack, 1);
        await tester.tap(find.text('날짜  ${day(expected)}'));
        await tester.pumpAndSettle();
        final calendar = tester.widget<CalendarDatePicker>(
          find.byType(CalendarDatePicker),
        );
        expect(day(calendar.initialDate!), day(expected));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [344.0, 1280.0]) {
    testWidgets(
      'transaction balances appear below amounts and follow the account filter at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        app.service.saveEntry(
          app.service.makeEntry(
            id: '000-transfer-balance',
            type: 'transfer',
            amount: 500000,
            account: 'bank',
            destination: 'saving',
            on: today(),
            memo: '정기 저축',
            allocations: [
              app.service.allocation(500000, '저축', subcategory: '적금'),
            ],
          ),
        );
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: ChagokApp(app: app),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('내역').last);
        await tester.pumpAndSettle();
        expect(find.text('2,507,000원'), findsNothing);
        expect(find.text('2,000,000원'), findsOneWidget);
        final transferAmount = find.descendant(
          of: find.byKey(const ValueKey('transaction/000-transfer-balance')),
          matching: find.text('500,000원'),
        );
        final scheme = Theme.of(tester.element(transferAmount)).colorScheme;
        expect(
          tester.widget<Text>(transferAmount).style!.color,
          scheme.onSurface,
        );
        expect(
          tester.getTopLeft(find.text('2,000,000원')).dy,
          greaterThan(tester.getTopLeft(find.text('500,000원').first).dy),
        );
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/screenshots').create(recursive: true);
          await File(
            'build/screenshots/ledger-balances-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('전체 계좌').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('정기 적금').last);
        await tester.pumpAndSettle();
        expect(find.text('2,000,000원'), findsOneWidget);
        expect(find.textContaining('출발 잔액'), findsNothing);
        expect(find.textContaining('도착 잔액'), findsNothing);
        expect(
          tester.widget<Text>(transferAmount).style!.color,
          scheme.primary,
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('생활비 통장').last);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(transferAmount).style!.color,
          scheme.onSurface,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [344.0, 1280.0]) {
    testWidgets(
      'saved entry keeps date order and selection follows the clicked row at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final category = store
            .all('category')
            .firstWhere((c) => c['name'] == '식비');
        for (var i = 0; i < 3; i++) {
          app.service.saveEntry(
            app.service.makeEntry(
              id: '000-$i',
              type: 'expense',
              amount: 1000,
              account: 'bank',
              on: '2026-01-04',
              allocations: [app.service.allocation(1000, '식비')],
            ),
          );
        }
        store.setLocal(
          'entry_draft',
          jsonEncode({
            'type': 'expense',
            'date': '2026-01-03',
            'amount': '12345',
            'account': 'bank',
            'category': category['id'],
            'memo': '새내역 표시 확인',
            'shares': [],
            'recurring': false,
          }),
        );
        await tester.pumpWidget(ChagokApp(app: app));
        await tester.pumpAndSettle();
        await tester.tap(find.text('내역').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('전체 계좌').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('정기 적금').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '메모·분류 검색'),
          '일치하지 않는 검색',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('내역 추가'));
        await tester.pumpAndSettle();
        expect(find.text('12,345'), findsOneWidget);
        await tester.ensureVisible(find.text('저장'));
        await tester.tap(find.text('저장'));
        await tester.pumpAndSettle();
        expect(find.byType(EntryEditor), findsNothing);
        expect(find.text('2026년 1월'), findsOneWidget);
        expect(find.text('전체 계좌'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, '메모·분류 검색'))
              .controller!
              .text,
          isEmpty,
        );
        final saved = find.textContaining('2026-01-03 · 새내역 표시 확인');
        expect(saved, findsOneWidget);
        expect(find.textContaining('방금 저장'), findsNothing);
        final newer = find.byKey(const ValueKey('transaction/000-0'));
        expect(
          tester.getTopLeft(newer).dy,
          lessThan(tester.getTopLeft(saved).dy),
        );
        final savedTile = find.ancestor(
          of: saved,
          matching: find.byType(ListTile),
        );
        expect(tester.widget<ListTile>(savedTile).selected, isTrue);
        await tester.tap(newer);
        await tester.pumpAndSettle();
        expect(tester.widget<ListTile>(newer).selected, isTrue);
        expect(tester.widget<ListTile>(savedTile).selected, isFalse);
        expect(
          store
              .all('entry')
              .singleWhere((e) => e['memo'] == '새내역 표시 확인')['amount'],
          12345,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final width in [344.0, 690.0, 1280.0]) {
    testWidgets(
      'editing category and memo retains ledger scroll and filters at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        store.saveBatch([
          for (var i = 0; i < 60; i++)
            (
              'entry',
              app.service.makeEntry(
                id: 'scroll-$i',
                type: 'expense',
                amount: 1000,
                account: 'bank',
                on: today(),
                memo: '09:${i.toString().padLeft(2, '0')} 스크롤 확인',
                allocations: [app.service.allocation(1000, '식비')],
              ),
            ),
        ]);
        await tester.pumpWidget(ChagokApp(app: app));
        await tester.pumpAndSettle();
        await tester.tap(find.text('내역').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('전체 계좌').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('생활비 통장').last);
        await tester.pumpAndSettle();
        final searchField = find.widgetWithText(TextField, '메모·분류 검색');
        await tester.enterText(searchField, '스크롤');
        await tester.pumpAndSettle();
        final list = find.byType(ListView);
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final tile = find.byKey(const ValueKey('transaction/scroll-30'));
        await tester.scrollUntilVisible(tile, 400, scrollable: scrollable);
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        final offset = tester
            .state<ScrollableState>(scrollable)
            .position
            .pixels;
        final top = tester.getTopLeft(tile).dy;
        expect(offset, greaterThan(1000));
        for (final category in ['쇼핑', '식비']) {
          await tester.tap(tile);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('수정'));
          await tester.tap(find.text('수정'));
          await tester.pumpAndSettle();
          final categoryField = find.widgetWithText(
            DropdownButtonFormField<String>,
            '대분류',
          );
          await tester.ensureVisible(categoryField);
          await tester.tap(categoryField);
          await tester.pumpAndSettle();
          await tester.tap(find.text(category).last);
          await tester.pumpAndSettle();
          final memoField = find.widgetWithText(TextField, '메모 (선택)');
          await tester.ensureVisible(memoField);
          await tester.enterText(memoField, '09:30 스크롤 확인 $category');
          await tester.ensureVisible(find.text('저장'));
          await tester.tap(find.text('저장'));
          await tester.pumpAndSettle();
          expect(find.byType(EntryEditor), findsNothing);
          expect(
            tester.state<ScrollableState>(scrollable).position.pixels,
            closeTo(offset, 0.1),
          );
          expect(tester.getTopLeft(tile).dy, closeTo(top, 0.1));
          expect(tester.widget<TextField>(searchField).controller!.text, '스크롤');
          expect(find.text('전체 계좌'), findsNothing);
          expect(tester.widget<ListTile>(tile).selected, isTrue);
          final updated = store.get('entry', 'scroll-30')!;
          expect(updated['memo'], '09:30 스크롤 확인 $category');
          expect(
            rows(updated['allocations']).single['category_name'],
            category,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final recurring in [false, true]) {
    testWidgets(
      'transfer editor saves category and subcategory recurring=$recurring',
      (tester) async {
        tester.view.physicalSize = const Size(690, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EntryEditor(
                app: app,
                initialType: 'transfer',
                recurring: recurring,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, '금액'), '50000');
        await tester.tap(find.text('도착 계좌').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('정기 적금').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('대분류 (선택)').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('저축').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('소분류 (선택)').last,
            matching: find.byType(DropdownButtonFormField<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('적금').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '메모 (선택)'),
          '분류 이동 테스트',
        );
        await tester.ensureVisible(find.text('저장'));
        await tester.tap(find.text('저장'));
        await tester.pumpAndSettle();
        final entry = store
            .all('entry')
            .singleWhere((e) => e['memo'] == '분류 이동 테스트');
        expect(rows(entry['allocations']).single['category_name'], '저축');
        expect(rows(entry['allocations']).single['subcategory_name'], '적금');
        if (recurring) {
          final rule = store.get('rule', entry['rule'] as String)!;
          expect(rows(rule['revisions']).last['subcategory_name'], '적금');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
