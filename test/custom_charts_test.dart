import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/custom_charts.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/app_controller.dart';
import 'package:chagok/ui/custom_charts.dart';
import 'package:flutter/material.dart';

void main() {
  late LedgerStore store;
  late LedgerService service;
  late String account;
  setUp(() {
    store = LedgerStore.memory();
    service = LedgerService(store);
    account = service.saveAccount(name: '통장');
  });
  tearDown(() => store.close());
  Json chart() => {
    'name': '내 생활비',
    'other': true,
    'groups': [
      {
        'name': '필수',
        'selectors': [
          {'category': '식비', 'sub': '식료품'},
          {'category': '생활', 'sub': null},
        ],
      },
      {
        'name': '여비',
        'selectors': [
          {'category': '식비', 'sub': '외식'},
        ],
      },
    ],
  };
  Json spend(int amount, String cat, String sub, {String on = '2026-07-01'}) {
    final e = service.makeEntry(
      type: 'expense',
      amount: amount,
      account: account,
      on: on,
      allocations: [service.allocation(amount, cat, subcategory: sub)],
    );
    service.saveEntry(e);
    return e;
  }

  test('mixed parent and child groups follow period and subtract refunds', () {
    final food = spend(10000, '식비', '식료품');
    spend(20000, '생활', '인터넷');
    spend(5000, '식비', '외식');
    spend(7000, '여가', '취미');
    spend(90000, '생활', '인터넷', on: '2026-08-01');
    service.refund(food['id'] as String, 2000, account, '2026-07-02');
    expect(customChartTotals(store, '2026-07', chart()), [
      ('필수', 28000),
      ('여비', 5000),
      ('그 외', 7000),
    ]);
    expect(customChartTotals(store, '2026-08', chart()), [
      ('필수', 90000),
      ('여비', 0),
      ('그 외', 0),
    ]);
    expect(customChartTotals(store, '2026-07', {...chart(), 'other': false}), [
      ('필수', 28000),
      ('여비', 5000),
    ]);
  });
  test('overlapping category selection is rejected without a save', () {
    final c = chart();
    (c['groups'] as List).last['selectors'] = [
      {'category': '식비', 'sub': null},
    ];
    expect(
      () => store.save('settings', {'id': 'chart', 'custom_chart': c}),
      throwsA(isA<LedgerException>()),
    );
    expect(store.get('settings', 'chart'), isNull);
  });
  testWidgets(
    'chart editor saves selected subcategory without modifying entries',
    (tester) async {
      tester.view.physicalSize = const Size(344, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      spend(10000, '식비', '식료품');
      final app = AppController(store, '.');
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CustomCharts(app: app, month: '2026-07'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('그래프 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '생활비 구성');
      await tester.tap(find.text('묶음 추가'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '생활 필수액');
      await tester.tap(find.text('식비'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('식료품'));
      await tester.tap(find.text('묶음 적용'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('그래프 저장'));
      await tester.pumpAndSettle();
      final saved = store.all('settings').single['custom_chart'] as Json;
      expect(customChartTotals(store, '2026-07', saved), [
        ('생활 필수액', 10000),
        ('그 외', 0),
      ]);
      expect(store.flow('2026-07', 'expense'), 10000);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'multiple charts persist through sync and deletion leaves entries intact',
    () {
      spend(1000, '생활', '인터넷');
      store.save('settings', {'id': 'chart1', 'custom_chart': chart()});
      store.save('settings', {
        'id': 'chart2',
        'custom_chart': {...chart(), 'name': '두번째'},
      });
      final peer = LedgerStore.memory(ledger: store.ledgerId);
      addTearDown(peer.close);
      peer.merge(store.events);
      expect(
        peer.all('settings').where((d) => d['custom_chart'] != null).length,
        2,
      );
      store.save('settings', {
        ...store.get('settings', 'chart1')!,
        'deleted': true,
      });
      peer.merge(store.events);
      expect(
        peer.all('settings').where((d) => d['custom_chart'] != null).length,
        1,
      );
      expect(peer.flow('2026-07', 'expense'), 1000);
    },
  );
}
