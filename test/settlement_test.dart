import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chagok/data/interchange.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/settlement_service.dart';
import 'package:chagok/domain/value.dart';

void main() {
  late LedgerStore store;
  late LedgerService service;
  late String account;
  setUp(() {
    store = LedgerStore.memory();
    service = LedgerService(store);
    account = service.saveAccount(
      name: '생활',
      opening: 100000,
      opened: '2026-01-01',
    );
  });
  tearDown(() => store.close());
  Json entry(String type, int amount, {String on = '2026-07-01'}) {
    final e = service.makeEntry(
      type: type,
      amount: amount,
      account: account,
      on: on,
      allocations: [service.allocation(amount, '기타')],
    );
    service.saveEntry(e);
    return e;
  }

  Json group(List<Json> entries) => {
    'id': uuid.v4(),
    'name': '공동 구매',
    'date': '2026-08-01',
    'memo': '',
    'category_name': '생활',
    'subcategory_name': '공동 구매',
    'members': entries.map((e) => e['id']).toList()..sort(),
    'claims': <Json>[],
    'closed': false,
  };
  test(
    'net flips expense, zero, income; original cash and purpose are preserved',
    () {
      final spend = entry('expense', 80000), pay = entry('income', 60000);
      final g = group([spend, pay]);
      service.saveSettlement(g);
      expect(store.balance(account), 80000);
      expect(store.flow('2026-07', 'expense'), 0);
      expect(store.flow('2026-08', 'expense'), 20000);
      expect(store.flow('2026', 'income'), 0);
      expect(
        store.entries(period: '2026-07', collapseSettlements: true),
        isEmpty,
      );
      expect(
        store
            .entries(
              period: '2026-07',
              account: account,
              collapseSettlements: true,
            )
            .length,
        2,
      );
      for (final amount in [80000, 90000]) {
        final updated = service.makeEntry(
          id: pay['id'] as String,
          type: 'income',
          amount: amount,
          account: account,
          on: '2026-07-01',
          allocations: [service.allocation(amount, '기타')],
        );
        service.saveEntry(updated);
        expect(store.flow('2026', 'expense'), 0);
        expect(store.flow('2026', 'income'), amount - 80000);
        final visible = store
            .entries(period: '2026-08', collapseSettlements: true)
            .single;
        expect(visible['amount'], amount - 80000);
        expect(visible['type'], amount == 80000 ? 'neutral' : 'income');
        expect(
          store.get('settlement_group', g['id'] as String)!['category_name'],
          '생활',
        );
      }
      final before = store.balance(account);
      store.remove('settlement_group', g['id'] as String);
      expect(store.balance(account), before);
      expect(store.flow('2026-07', 'income'), 90000);
      expect(store.flow('2026-07', 'expense'), 80000);
    },
  );
  test(
    'checklist and debt conversion never create cash; repeat conversion is blocked',
    () {
      final g = group([entry('expense', 10000), entry('income', 5000)]);
      g['claims'] = [
        {
          'id': 'claim',
          'person': '친구',
          'amount': 4000,
          'memo': '',
          'received': false,
        },
      ];
      service.saveSettlement(g);
      final balance = store.balance(account),
          cost = store.flow('2026', 'expense');
      service.setClaimReceived(g['id'] as String, 'claim', true);
      expect(store.balance(account), balance);
      expect(store.flow('2026', 'expense'), cost);
      expect(
        () => service.transferClaimToDebt(g['id'] as String, 'claim'),
        throwsA(isA<LedgerException>()),
      );
      service.setClaimReceived(g['id'] as String, 'claim', false);
      final debt = service.transferClaimToDebt(g['id'] as String, 'claim');
      expect(service.debtBalance(store.get('debt', debt)!), 4000);
      expect(store.balance(account), balance);
      expect(store.flow('2026', 'expense'), cost);
      expect(
        () => service.transferClaimToDebt(g['id'] as String, 'claim'),
        throwsA(isA<LedgerException>()),
      );
      expect(store.all('debt').length, 1);
    },
  );
  test(
    'ineligible edits roll back; deletion and unlink recalculate automatically',
    () {
      final a = entry('expense', 10000), b = entry('income', 5000);
      final g = group([a, b]);
      service.saveSettlement(g);
      final destination = service.saveAccount(name: '저축');
      expect(
        () => service.saveEntry(
          service.makeEntry(
            id: a['id'] as String,
            type: 'transfer',
            amount: 10000,
            account: account,
            destination: destination,
            on: '2026-07-01',
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      expect(store.balance(destination), 0);
      expect(
        () => service.saveSettlement(group([a])),
        throwsA(isA<LedgerException>()),
      );
      store.remove('entry', b['id'] as String);
      expect(store.flow('2026', 'expense'), 10000);
      service.saveSettlement({...g, 'members': []});
      expect(store.flow('2026-07', 'expense'), 10000);
      expect(store.flow('2026-08', 'expense'), 0);
    },
  );
  test(
    'out of order sync waits for complete references; overlapping groups never double count',
    () {
      final a = entry('expense', 10000),
          b = entry('income', 5000),
          g = group([]);
      g['members'] = [a['id'], b['id']];
      service.saveSettlement(g);
      final peer = LedgerStore.memory(ledger: store.ledgerId);
      addTearDown(peer.close);
      peer.merge(
        store.events.where((e) => e['kind'] == 'settlement_group').toList(),
      );
      expect(peer.pending, isNotEmpty);
      peer.merge(
        store.events.where((e) => e['kind'] != 'settlement_group').toList(),
      );
      expect(peer.pending, isEmpty);
      expect(peer.flow('2026', 'expense'), 5000);
      final other = LedgerStore.memory(ledger: store.ledgerId);
      addTearDown(other.close);
      other.merge(
        store.events.where((e) => e['kind'] != 'settlement_group').toList(),
      );
      LedgerService(other).saveSettlement(group([a, b]));
      peer.merge(other.events);
      expect(peer.pending, isNotEmpty);
      expect(peer.flow('2026', 'expense'), 10000);
      expect(peer.flow('2026', 'income'), 5000);
      expect(
        peer.entries(period: '2026-07', collapseSettlements: true).length,
        2,
      );
    },
  );
  test('schema 1 imports remain readable and new writes require schema 2', () {
    final oldAccountEvent = copyJson(store.events.single);
    oldAccountEvent['schema'] = 1;
    oldAccountEvent['id'] = LedgerStore.eventId(oldAccountEvent);
    final peer = LedgerStore.memory(ledger: store.ledgerId);
    addTearDown(peer.close);
    peer.merge([oldAccountEvent]);
    expect(peer.balance(account), 100000);
    LedgerService(peer).saveAccount(name: '새 계좌');
    expect(peer.events.where((e) => e['schema'] == 2), hasLength(1));
    final invalid = {...oldAccountEvent, 'schema': 3};
    invalid['id'] = LedgerStore.eventId(invalid);
    expect(() => peer.merge([invalid]), throwsA(isA<LedgerException>()));
  });
  test('closed groups protect original transactions until reopened', () {
    final a = entry('expense', 10000), g = group([]);
    g['members'] = [a['id']];
    g['closed'] = true;
    service.saveSettlement(g);
    expect(
      () => store.remove('entry', a['id'] as String),
      throwsA(isA<LedgerException>()),
    );
    service.saveSettlement({...g, 'closed': false});
    store.remove('entry', a['id'] as String);
    expect(store.flow('2026', 'expense'), 0);
  });

  Uint8List workbook({
    String reference = 'purchase',
    bool amountColumn = false,
  }) {
    final book = Excel.createExcel();
    book.rename('Sheet1', '내역');
    void write(String name, List<List<Object>> rows) {
      for (final row in rows) {
        book[name].appendRow(
          row
              .map<CellValue>(
                (v) => v is int ? IntCellValue(v) : TextCellValue('$v'),
              )
              .toList(),
        );
      }
    }

    write('내역', [
      Interchange.headers,
      ['', '', '2026-07-01', '지출', 10000, '생활', '', '기타', '', '구매', 'purchase'],
      ['', '', '2026-07-02', '수입', 12000, '생활', '', '기타', '', '받음', 'receipt'],
    ]);
    write('정산 묶음', [
      [
        '정산키',
        '정산ID',
        '기준버전',
        '이름',
        '기준일',
        '대분류',
        '소분류',
        '메모',
        if (amountColumn) '금액',
      ],
      [
        'test',
        '',
        '',
        '공동 구매',
        '2026-07-02',
        '생활',
        '공동',
        '',
        if (amountColumn) 2000,
      ],
    ]);
    write('정산 연결', [
      ['정산키', '거래참조'],
      ['test', reference],
      ['test', 'receipt'],
    ]);
    return Uint8List.fromList(book.encode()!);
  }

  test(
    'Excel references import atomically; groups have no amount; repeat import is idempotent',
    () {
      final io = Interchange(service), bytes = workbook();
      final preview = io.preview(bytes, 'xlsx');
      expect(preview.length, 3);
      expect(preview.last.entry!.containsKey('amount'), false);
      expect(
        () => io.apply(preview.take(2).toList()),
        throwsA(isA<LedgerException>()),
      );
      expect(store.all('entry'), isEmpty);
      expect(
        () => io.apply([preview.first, preview.last]),
        throwsA(isA<LedgerException>()),
      );
      io.apply(preview);
      expect(store.balance(account), 102000);
      expect(store.flow('2026', 'income'), 2000);
      expect(store.flow('2026', 'expense'), 0);
      final count = store.events.length;
      final repeat = io.preview(bytes, 'xlsx');
      expect(repeat.every((r) => r.action == '변경 없음'), true);
      io.apply(repeat);
      expect(store.events.length, count);
      final roundtrip = io.preview(io.excelBytes(), 'xlsx');
      expect(
        roundtrip.every((r) => r.error == null && r.action == '변경 없음'),
        true,
      );
      io.apply(roundtrip);
      expect(store.events.length, count);
      final restored = LedgerStore.memory();
      addTearDown(restored.close);
      restored.restoreBackup(store.exportBackup(), asNew: false);
      expect(restored.flow('2026', 'income'), 2000);
      expect(restored.balance(account), 102000);
    },
  );
  test(
    'Excel rejects dangling links, amount columns and stale imports without writes',
    () {
      final io = Interchange(service);
      expect(
        () => io.preview(workbook(reference: 'missing'), 'xlsx'),
        throwsA(isA<LedgerException>()),
      );
      expect(
        () => io.preview(workbook(amountColumn: true), 'xlsx'),
        throwsA(isA<LedgerException>()),
      );
      final preview = io.preview(workbook(), 'xlsx');
      service.saveEntry({...preview.first.entry!, 'memo': 'changed'});
      final count = store.events.length;
      expect(() => io.apply(preview), throwsA(isA<LedgerException>()));
      expect(store.events.length, count);
      expect(store.all('settlement_group'), isEmpty);
    },
  );
}
