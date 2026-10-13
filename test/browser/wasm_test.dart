@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:chagok/data/database_web.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';

void main() {
  setUpAll(
    () => initializeDatabase(wasmUri: Uri.base.resolve('../sqlite3.wasm')),
  );
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
