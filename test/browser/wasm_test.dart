@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:chagok/data/database_web.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/settlement_service.dart';

void main() {
  setUpAll(
    () => initializeDatabase(wasmUri: Uri.base.resolve('../sqlite3.wasm')),
  );
  test('browser settlement projection survives device checkpoint', () {
    final store = LedgerStore.memory();
    addTearDown(store.close);
    final service = LedgerService(store);
    final account = service.saveAccount(name: '공동 구매', opening: 100000);
    final members = <String>[];
    for (final (type, amount) in [('expense', 80000), ('income', 90000)]) {
      final e = service.makeEntry(
        type: type,
        amount: amount,
        account: account,
        on: '2026-07-01',
        allocations: [service.allocation(amount, '기타')],
      );
      service.saveEntry(e);
      members.add(e['id'] as String);
    }
    service.saveSettlement({
      'id': 'group',
      'name': '공동 구매',
      'date': '2026-07-01',
      'memo': '',
      'category_name': '생활',
      'members': members,
      'claims': [],
      'closed': false,
    });
    expect(store.balance(account), 110000);
    expect(store.flow('2026-07', 'income'), 10000);
    expect(store.flow('2026-07', 'expense'), 0);
    expect(
      store.entries(period: '2026-07', collapseSettlements: true).length,
      1,
    );
    final reopened = LedgerStore.memory();
    addTearDown(reopened.close);
    reopened.loadCheckpoint(store.checkpoint());
    expect(reopened.balance(account), 110000);
    expect(reopened.flow('2026-07', 'income'), 10000);
  });
  test('real browser SQLite preserves Korean and integers above 32 bits', () {
    final store = LedgerStore.memory();
    addTearDown(store.close);
    final service = LedgerService(store);
    final account = service.saveAccount(name: '생활비 통장', opening: 999999999999);
    service.saveEntry(
      service.makeEntry(
        type: 'expense',
        amount: 90000,
        account: account,
        on: '2026-10-13',
        allocations: [service.allocation(30000, '식비', subcategory: '외식')],
        shares: [
          {'id': 'friend', 'person': '친구', 'amount': 60000},
        ],
      ),
    );
    expect(store.balance(account), 999999909999);
    expect(
      store
          .query('SELECT SUM(amount) n FROM transaction_allocations')
          .single['n'],
      30000,
    );
    expect(
      store
          .query('SELECT subcategory_name n FROM transaction_allocations')
          .single['n'],
      '외식',
    );
    expect(store.all('account').single['name'], '생활비 통장');
  });
  test(
    'browser orders imported times newest first and balances oldest first',
    () {
      final store = LedgerStore.memory();
      addTearDown(store.close);
      final service = LedgerService(store);
      final account = service.saveAccount(
        name: '시간 통장',
        opening: 1000,
        opened: '2026-01-01',
      );
      for (final (id, memo) in [('a', '09:00 첫 거래'), ('z', '20:00 마지막 거래')]) {
        service.saveEntry(
          service.makeEntry(
            id: id,
            type: 'income',
            amount: 100,
            account: account,
            on: '2026-01-01',
            memo: memo,
            allocations: [service.allocation(100, '기타')],
          ),
        );
      }
      final entries = store.entries(account: account);
      expect(entries.map((e) => e['id']), ['z', 'a', 'opening:$account']);
      expect(
        entries.map((e) => (e['balances'] as List).single['balance_after']),
        [1200, 1100, 1000],
      );
    },
  );
  test(
    'browser checkpoint rehydrates SQL and native JSON backup migrates without amount changes',
    () {
      final store = LedgerStore.memory(),
          restored = LedgerStore.memory(),
          backup = LedgerStore.memory();
      addTearDown(store.close);
      addTearDown(restored.close);
      addTearDown(backup.close);
      final service = LedgerService(store);
      final account = service.saveAccount(name: '통장', opening: 3000000);
      final savings = service.saveAccount(name: '적금', kind: 'savings');
      service.saveEntry(
        service.makeEntry(
          type: 'transfer',
          amount: 500000,
          account: account,
          destination: savings,
          on: '2026-10-13',
        ),
      );
      restored.loadCheckpoint(store.checkpoint());
      expect(restored.balance(account), 2500000);
      expect(restored.balance(savings), 500000);
      final transfer = restored.entries(account: savings).single;
      expect((transfer['balances'] as List).single['balance_after'], 500000);
      backup.restoreBackup(store.exportBackup());
      expect(backup.ledgerId, isNot(store.ledgerId));
      expect(backup.all('account'), hasLength(2));
      expect(
        backup.query('SELECT SUM(delta) n FROM postings').single['n'],
        3000000,
      );
    },
  );
}
