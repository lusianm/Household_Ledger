import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/data/interchange.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/sync/drive_sync.dart';

void main() {
  late LedgerStore store;
  late LedgerService service;
  late String a, b;
  setUp(() {
    store = LedgerStore.memory();
    service = LedgerService(store);
    a = service.saveAccount(name: '생활비', opening: 1000000);
    b = service.saveAccount(name: '적금', kind: 'savings', liquid: false);
  });
  tearDown(() => store.close());
  Json expense({int amount = 90000, List<Json> shares = const []}) =>
      service.makeEntry(
        type: 'expense',
        amount: amount,
        account: a,
        on: '2026-01-12',
        memo: '모임',
        allocations: [
          service.allocation(
            amount - sumMoney(shares.map((s) => s['amount'] as int)),
            '식비',
            subcategory: '외식',
          ),
        ],
        shares: shares,
      );
  LedgerStore peer() {
    final p = LedgerStore.memory(ledger: store.ledgerId);
    p.merge(store.events);
    addTearDown(p.close);
    return p;
  }

  test('transfer changes both balances but never income or expense', () {
    service.saveEntry(
      service.makeEntry(
        type: 'transfer',
        amount: 500000,
        account: a,
        destination: b,
        on: '2026-01-10',
      ),
    );
    expect(store.balance(a), 500000);
    expect(store.balance(b), 500000);
    expect(store.flow('2026', 'expense'), 0);
    expect(store.flow('2026', 'income'), 0);
    expect(
      () => service.makeEntry(
        type: 'transfer',
        amount: 1,
        account: a,
        destination: a,
        on: '2026-01-10',
      ),
      throwsA(isA<LedgerException>()),
    );
  });
  test(
    'partial settlement keeps expense at own share and receipts out of income',
    () {
      final e = expense(
        shares: [
          {'id': 's1', 'person': '민수', 'amount': 30000},
          {'id': 's2', 'person': '지연', 'amount': 30000},
        ],
      );
      service.saveEntry(e);
      service.receive(e['id'] as String, 's1', 20000, a, '2026-02-01');
      expect(store.flow('2026-01', 'expense'), 30000);
      expect(store.flow('2026-02', 'income'), 0);
      expect(store.balance(a), 930000);
      final saved = store.get('entry', e['id'] as String)!;
      expect(service.remainingShare(saved, rows(saved['shares']).first), 10000);
      expect(
        () => service.receive(e['id'] as String, 's1', 20000, a, '2026-02-02'),
        throwsA(isA<LedgerException>()),
      );
      expect(store.balance(a), 930000);
      expect(
        () => store.remove('entry', e['id'] as String),
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test('debt ledger without linked cash never changes assets', () {
    final id = service.createDebt(
      person: '현우',
      direction: 'lent',
      amount: 100000,
      on: '2026-01-01',
    );
    expect(store.balance(a), 1000000);
    service.debtEvent(id, 40000, '2026-01-02', account: a);
    expect(service.debtBalance(store.get('debt', id)!), 60000);
    expect(store.balance(a), 1040000);
    expect(store.flow('2026', 'income'), 0);
    expect(
      () => service.debtEvent(id, 70000, '2026-01-03'),
      throwsA(isA<LedgerException>()),
    );
  });
  test('category rename and delete preserve historical strings', () {
    service.saveCategory('expense', '식비');
    final parent = store.all('category').single;
    final e = expense();
    e['allocations'] = [
      service.allocation(90000, '식비', categoryId: parent['id'] as String),
    ];
    service.saveEntry(e);
    service.saveCategory('expense', '먹거리', id: parent['id'] as String);
    service.deleteCategory(parent['id'] as String);
    expect(store.allocations(e['id'] as String).single['category_name'], '식비');
    expect(store.flow('2026', 'expense'), 90000);
  });
  test('refund is negative expense and can be cancelled', () {
    final e = expense(amount: 10001);
    service.saveEntry(e);
    service.refund(e['id'] as String, 4000, a, '2026-01-13');
    expect(store.flow('2026', 'expense'), 6001);
    expect(store.flow('2026', 'income'), 0);
    final r = rows(store.get('entry', e['id'] as String)!['refunds']).single;
    service.voidChild('entry', e['id'] as String, 'refunds', r['id'] as String);
    expect(store.flow('2026', 'expense'), 10001);
  });
  Json rule({
    String start = '2026-01-31',
    String cycle = 'monthly',
    String type = 'transfer',
    int anchor = 31,
    int month = 1,
  }) => {
    'type': type,
    'amount': 50000,
    'account': a,
    'destination': b,
    'category_name': '급여',
    'subcategory_name': '월급',
    'category_id': null,
    'subcategory_id': null,
    'cycle': cycle,
    'start': start,
    'end': null,
    'effective': start,
    'anchor_day': anchor,
    'anchor_month': month,
    'memo': '자동',
  };
  test('monthly recurrence clamps short months and keeps original day', () {
    service.saveRule(rule());
    expect(service.generateDue(until: '2026-03-31'), 3);
    expect(
      store
          .query(
            'SELECT scheduled_on FROM recurring_occurrences ORDER BY scheduled_on',
          )
          .map((r) => r['scheduled_on']),
      ['2026-01-31', '2026-02-28', '2026-03-31'],
    );
    expect(service.generateDue(until: '2026-03-31'), 0);
    expect(store.flow('2026', 'expense'), 0);
    store.remove('entry', store.all('entry').first['id'] as String);
    expect(service.generateDue(until: '2026-03-31'), 0);
  });
  test('leap-year recurrence returns to February 29', () {
    service.saveRule(
      rule(start: '2024-02-29', cycle: 'yearly', anchor: 29, month: 2),
    );
    service.generateDue(until: '2026-03-01');
    expect(
      store
          .query(
            'SELECT scheduled_on FROM recurring_occurrences ORDER BY scheduled_on',
          )
          .map((r) => r['scheduled_on']),
      ['2024-02-29', '2025-02-28', '2026-02-28'],
    );
  });
  test('future recurring income is not money already received', () {
    service.saveRule(rule(start: '2099-01-31', type: 'income'));
    service.generateDue();
    expect(store.balance(a), 1000000);
    expect(store.flow('2099', 'income'), 0);
  });
  test(
    'two devices generating same occurrence converge without duplicates',
    () {
      service.saveRule(rule());
      final p = peer();
      service.generateDue(until: '2026-02-28');
      LedgerService(p).generateDue(until: '2026-02-28');
      store.merge(p.events);
      p.merge(store.events);
      expect(store.conflicts, isEmpty);
      expect(store.all('entry').length, 2);
      expect(p.balance(b), 100000);
      expect(store.balance(b), 100000);
    },
  );
  test('concurrent edits retain common base in either delivery order', () {
    final e = expense(amount: 10000);
    service.saveEntry(e);
    final p = peer();
    final left = copyJson(e)..['memo'] = '왼쪽';
    final right = copyJson(e)..['memo'] = '오른쪽';
    service.saveEntry(left);
    LedgerService(p).saveEntry(right);
    store.merge(p.events.reversed.toList());
    p.merge(store.events.reversed.toList());
    final key = 'entry/${e['id']}';
    expect(store.conflicts.keys, contains(key));
    expect(store.get('entry', e['id'] as String)!['memo'], '모임');
    expect(p.get('entry', e['id'] as String)!['memo'], '모임');
    store.resolve(key, left);
    p.merge(store.events);
    expect(p.conflicts, isEmpty);
    expect(p.get('entry', e['id'] as String)!['memo'], '왼쪽');
  });
  test('independent full receipts conflict instead of over-receiving', () {
    final e = expense(
      shares: [
        {'id': 's1', 'person': '민수', 'amount': 60000},
      ],
    );
    service.saveEntry(e);
    final p = peer();
    service.receive(e['id'] as String, 's1', 60000, a, '2026-01-13');
    LedgerService(p).receive(e['id'] as String, 's1', 60000, a, '2026-01-13');
    store.merge(p.events);
    expect(store.conflicts, isNotEmpty);
    expect(store.balance(a), 910000);
    expect(store.flow('2026', 'expense'), 30000);
  });
  test(
    'invalid sync batch rolls back all changes and foreign ledgers are rejected',
    () {
      final p = peer();
      final e = expense(amount: 4000);
      service.saveEntry(e);
      final corrupt = copyJson(store.events.last)..['id'] = 'tampered';
      expect(
        () => p.merge([...store.events, corrupt]),
        throwsA(isA<LedgerException>()),
      );
      expect(p.all('entry'), isEmpty);
      final foreign = LedgerStore.memory();
      addTearDown(foreign.close);
      expect(
        () => foreign.merge(store.events),
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test(
    'file persistence and backup restore retain amounts with new ledger identity',
    () {
      final e = expense();
      service.saveEntry(e);
      final backup = store.exportBackup();
      final folder = Directory.systemTemp.createTempSync('chagok-test-');
      final file = '${folder.path}/ledger.db';
      final disk = LedgerStore(file);
      disk.restoreBackup(backup);
      final newLedger = disk.ledgerId;
      expect(newLedger, isNot(store.ledgerId));
      disk.close();
      final reopened = LedgerStore(file);
      expect(reopened.balance(a), 910000);
      expect(reopened.ledgerId, newLedger);
      reopened.close();
      folder.deleteSync(recursive: true);
    },
  );
  test('xlsx roundtrip and string-only category import', () {
    service.saveEntry(expense(amount: 12000));
    final io = Interchange(service);
    final preview = io.preview(io.excelBytes(), 'xlsx');
    expect(preview.single.error, isNull);
    expect(preview.single.action, '변경 없음');
    service.saveCategory('expense', '식비', id: 'food');
    final original = store.all('entry').single;
    original['allocations'][0]['category_id'] = 'food';
    service.saveEntry(original);
    service.deleteCategory('food');
    expect(io.preview(io.excelBytes(), 'xlsx').single.action, '변경 없음');
    final csv = utf8.encode(
      '날짜,유형,금액,계좌,대분류,소분류,메모\r\n2026-01-02,지출,1234,생활비,옛 분류,옛 소분류,과거 기록\r\n',
    );
    final imported = io.preview(Uint8List.fromList(csv), 'csv');
    expect(imported.single.error, isNull);
    io.apply(imported);
    final allocation = store
        .allocations(imported.single.entry!['id'] as String)
        .single;
    expect(allocation['category_name'], '옛 분류');
    expect(allocation['category_id'], isNull);
  });
  test('sync retry is idempotent after upload acknowledgement loss', () async {
    final transport = MemoryTransport()..failOnce = true;
    final sync = SyncEngine(store, transport);
    await expectLater(sync.synchronize(), throwsA(isA<LedgerException>()));
    await sync.synchronize();
    final p = peer();
    await SyncEngine(p, transport).synchronize();
    expect(p.balance(a), store.balance(a));
    expect(store.unsent, 0);
  });
  test('restored ledger does not regenerate old recurring occurrences', () {
    service.saveRule(rule());
    service.generateDue(until: '2026-03-31');
    final edited = store.all('entry').first;
    edited['date'] = '2026-03-31';
    service.saveEntry(edited);
    final target = LedgerStore.memory();
    addTearDown(target.close);
    target.restoreBackup(store.exportBackup());
    expect(LedgerService(target).generateDue(until: '2026-03-31'), 0);
    expect(target.balance(a), store.balance(a));
  });
  test('skipping a future occurrence never affects current balances', () {
    final id = service.saveRule(rule(start: '2099-01-31'));
    service.skipOccurrence(store.get('rule', id)!, '2099-01-31');
    expect(store.balance(a), 1000000);
    expect(
      store.query('SELECT status FROM recurring_occurrences').single['status'],
      'skipped',
    );
    expect(service.nextOccurrence(store.get('rule', id)!), isNull);
  });
  test('missing receipt account defers the whole financial aggregate', () {
    final other = peer();
    final before = store.events.map((e) => e['id']).toSet();
    final remote = LedgerService(other);
    final cash = remote.saveAccount(name: '새 통장');
    final e = expense(
      shares: [
        {'id': 'friend', 'person': '친구', 'amount': 60000},
      ],
    );
    remote.saveEntry(e);
    remote.receive(e['id'] as String, 'friend', 30000, cash, '2026-01-12');
    final changes = other.events
        .where((e) => !before.contains(e['id']))
        .toList();
    store.merge(changes.where((e) => e['kind'] != 'account').toList());
    expect(store.balance(a), 1000000);
    expect(store.pending, isNotEmpty);
    service.saveCategory('expense', '새 분류');
    store.merge(changes.where((e) => e['kind'] == 'account').toList());
    expect(store.balance(a), 910000);
    expect(store.balance(cash), 30000);
    expect(store.flow('2026-01', 'expense'), 30000);
    expect(store.pending, isEmpty);
  });
}

class MemoryTransport implements ChangeTransport {
  final List<Json> changes = [];
  bool failOnce = false;
  @override
  Future<List<Json>> read(String ledger) async => changes;
  @override
  Future<void> write(String ledger, Json event) async {
    changes.add(copyJson(event));
    if (failOnce) {
      failOnce = false;
      throw const LedgerException('응답 유실');
    }
  }
}
