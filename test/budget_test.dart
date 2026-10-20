import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/budget.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/ui/budget_panel.dart';

void main() {
  late LedgerStore store;
  late LedgerService service;
  setUp(() {
    store = LedgerStore.memory();
    service = LedgerService(store);
    final account = service.saveAccount(name: '생활비');
    for (final (amount, cat, sub) in [
      (10000, '식비', '식료품'),
      (5000, '식비', '외식'),
    ]) {
      final e = service.makeEntry(
        type: 'expense',
        amount: amount,
        account: account,
        on: '2026-07-01',
        allocations: [service.allocation(amount, cat, subcategory: sub)],
      );
      service.saveEntry(e);
      if (sub == '식료품') {
        service.refund(e['id'] as String, 2000, account, '2026-07-02');
      }
    }
  });
  tearDown(() => store.close());
  Json budget(String mode, {int amount = 10000}) => {
    'id': 'budget',
    'month': '2026-07',
    'category': null,
    'amount': amount,
    'filter_mode': mode,
    'selectors': [
      {'category': '식비', 'sub': '식료품'},
    ],
  };
  test('include and exclude subcategories partition actual net expenses', () {
    expect(budgetUsed(store, budget('all')), 13000);
    expect(budgetUsed(store, budget('include')), 8000);
    expect(budgetUsed(store, budget('exclude')), 5000);
    expect(budgetUsed(store, {...budget('include'), 'month': '2026-08'}), 0);
    expect(
      budgetUsed(store, {
        ...budget('include'),
        'selectors': [
          {'category': '식비', 'sub': null},
        ],
      }),
      13000,
    );
    expect(budgetUsed(store, {'month': '2026-07', 'amount': 10000}), 13000);
  });
  test('empty filtered selection is rejected and filter survives sync', () {
    expect(
      () => store.save('budget', {...budget('include'), 'selectors': <Json>[]}),
      throwsA(isA<LedgerException>()),
    );
    store.save('budget', budget('exclude'));
    final peer = LedgerStore.memory(ledger: store.ledgerId);
    addTearDown(peer.close);
    peer.merge(store.events);
    expect(budgetUsed(peer, peer.get('budget', 'budget')!), 5000);
  });
  testWidgets('used amount is blue at limit and red only when exceeded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(344, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppController(store, '.');
    addTearDown(app.dispose);
    Future<void> render(int amount) async {
      store.save('budget', budget('include', amount: amount));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BudgetPanel(app: app, month: '2026-07'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await render(8000);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('budget-used')))
          .style!
          .color,
      const Color(0xff1769cc),
    );
    expect(find.text('0원 남음'), findsOneWidget);
    await render(7000);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('budget-used')))
          .style!
          .color,
      const Color(0xffcf3030),
    );
    expect(find.text('1,000원 초과 사용'), findsOneWidget);
    await tester.tap(find.text('예산 수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '20000');
    await tester.tap(find.text('예산 저장'));
    await tester.pumpAndSettle();
    expect(store.get('budget', 'budget')!['amount'], 20000);
    expect(store.get('budget', 'budget')!['filter_mode'], 'include');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
