import 'dart:convert';
import 'package:chagok/data/file_connection.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/value.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LedgerStore store;
  late LedgerService service;
  late FileConnection connection;
  late String bank, wallet, entry;
  String? request;
  Json? disk;
  var failSave = false, failResult = false, backups = 0, paused = false;
  void Function()? duringBackup;
  late Map<String, Json> files;
  Json operation(String id, Json patch) => {
    'id': id,
    'base': digest(store.get('entry', id)),
    'set': patch,
  };
  Json batch(List<Json> operations, {String id = 'request-1'}) => {
    'format': 'chagok-file-request',
    'version': 1,
    'id': id,
    'ledger': store.ledgerId,
    'connection': connection.session,
    'operations': operations,
  };

  setUp(() {
    store = LedgerStore.memory();
    service = LedgerService(store);
    bank = service.saveAccount(name: 'NH 농협', opening: 1000000);
    wallet = service.saveAccount(name: '카카오톡 지갑', kind: 'cash');
    final e = service.makeEntry(
      type: 'expense',
      amount: 36730,
      account: bank,
      on: '2026-07-11',
      memo: '20:14 카카오페이',
      allocations: [service.allocation(36730, '기타')],
    );
    e['import_key'] = 'existing-import-key';
    entry = e['id'] as String;
    service.saveEntry(e);
    store.setLocal(FileConnection.sessionKey, 'session');
    request = null;
    disk = null;
    failSave = failResult = paused = false;
    backups = 0;
    duringBackup = null;
    files = {};
    connection = FileConnection(
      service: service,
      paused: () => paused,
      readRequest: () async => request,
      flush: () async {
        if (failSave) throw StateError('disk full');
        disk = store.checkpoint();
      },
      backup: () async {
        backups++;
        duringBackup?.call();
        return 'backups/before-codex-test.json';
      },
      write: (name, value) async {
        if (name == 'result.json' && failResult) throw StateError('result IO');
        files[name] = value;
      },
    );
  });
  tearDown(() => store.close());

  test(
    'transfer updates both balances, expense totals and sync events before acknowledgement',
    () async {
      request = jsonEncode(
        batch([
          operation(entry, {'type': 'transfer', 'destination': wallet}),
        ]),
      );
      final events = store.events.length;
      await connection.poll();
      expect(connection.error, isNull);
      expect(store.balance(bank), 963270);
      expect(store.balance(wallet), 36730);
      expect(store.flow('2026-07', 'expense'), 0);
      expect(store.get('entry', entry)!['import_key'], 'existing-import-key');
      expect(store.events.length, events + 1);
      expect(store.unsent, greaterThan(0));
      expect(files['result.json']!['status'], 'applied');
      expect(files['result.json']!['backup'], contains('before-codex'));
      final recovered = LedgerStore.memory();
      addTearDown(recovered.close);
      recovered.loadCheckpoint(disk!);
      expect(recovered.balance(wallet), 36730);
      expect(recovered.local(FileConnection.receiptKey), isNotNull);
      await connection.poll();
      expect(store.events.length, events + 1);
      expect(backups, 1);
    },
  );

  test('category changes preserve identity and amounts', () async {
    request = jsonEncode(
      batch([
        operation(entry, {'category': '식비', 'subcategory': '간식'}),
      ]),
    );
    await connection.poll();
    final e = store.get('entry', entry)!;
    expect(e['amount'], 36730);
    expect(rows(e['allocations']).single['category_name'], '식비');
    expect(rows(e['allocations']).single['subcategory_name'], '간식');
    expect(store.balance(bank), 963270);
    expect(files['result.json']!['status'], 'applied');
  });

  test(
    'one stale row rejects the entire batch without backup or partial writes',
    () async {
      final second = service.makeEntry(
        type: 'expense',
        amount: 1000,
        account: bank,
        on: '2026-07-12',
        allocations: [service.allocation(1000, '기타')],
      );
      service.saveEntry(second);
      final valid = operation(entry, {'memo': 'changed'});
      final stale = operation(second['id'] as String, {'memo': 'stale'});
      service.saveEntry({...second, 'memo': 'edited in app'});
      final before = store.events.length;
      request = jsonEncode(batch([valid, stale]));
      await connection.poll();
      expect(files['result.json']!['status'], 'rejected');
      expect(store.events.length, before);
      expect(store.get('entry', entry)!['memo'], '20:14 카카오페이');
      expect(backups, 0);
    },
  );

  test('UI edits during backup are checked again', () async {
    request = jsonEncode(
      batch([
        operation(entry, {'memo': 'external'}),
      ]),
    );
    duringBackup = () =>
        service.saveEntry({...store.get('entry', entry)!, 'memo': 'UI wins'});
    await connection.poll();
    expect(files['result.json']!['status'], 'rejected');
    expect(store.get('entry', entry)!['memo'], 'UI wins');
    expect(store.local(FileConnection.receiptKey), isNull);
  });

  test(
    'no success is published for a failed checkpoint; retry does not apply twice',
    () async {
      request = jsonEncode(
        batch([
          operation(entry, {'memo': 'updated'}),
        ]),
      );
      duringBackup = () => failSave = true;
      final events = store.events.length;
      await connection.poll();
      expect(connection.error, contains('disk full'));
      expect(files['result.json'], isNull);
      expect(store.events.length, events + 1);
      failSave = false;
      await connection.poll();
      expect(files['result.json']!['status'], 'applied');
      expect(store.events.length, events + 1);
      expect(backups, 1);
    },
  );

  test('receipt survives restart after result publication fails', () async {
    request = jsonEncode(
      batch([
        operation(entry, {'memo': 'updated'}),
      ]),
    );
    failResult = true;
    await connection.poll();
    final events = store.events.length;
    store.close();
    store = LedgerStore.memory();
    store.loadCheckpoint(disk!);
    service = LedgerService(store);
    connection = FileConnection(
      service: service,
      flush: () async {},
      backup: () async => throw StateError('must not replay'),
      readRequest: () async => request,
      paused: () => false,
      write: (name, value) async => files[name] = value,
    );
    await connection.poll();
    expect(files['result.json']!['status'], 'applied');
    expect(store.events.length, events);
  });

  test(
    'wrong ledger, old connection, duplicate IDs and invalid amounts are rejected',
    () async {
      final cases = [
        {
          ...batch([
            operation(entry, {'memo': 'x'}),
          ]),
          'ledger': 'other',
        },
        {
          ...batch([
            operation(entry, {'memo': 'x'}),
          ]),
          'connection': 'old',
        },
        batch([
          operation(entry, {'memo': 'x'}),
          operation(entry, {'memo': 'y'}),
        ]),
        batch([
          operation(entry, {'amount': -1}),
        ]),
        batch([
          operation(entry, {'type': 'transfer', 'destination': bank}),
        ]),
      ];
      final events = store.events.length;
      for (final value in cases) {
        request = jsonEncode(value);
        await connection.poll();
        expect(files['result.json']!['status'], 'rejected');
        expect(store.events.length, events);
      }
    },
  );

  test('disabled or paused connection never processes requests', () async {
    request = jsonEncode(
      batch([
        operation(entry, {'memo': 'x'}),
      ]),
    );
    paused = true;
    await connection.poll();
    paused = false;
    store.removeLocal(FileConnection.sessionKey);
    await connection.poll();
    expect(files, isEmpty);
    expect(backups, 0);
  });

  test('malformed JSON is visible and does not change the ledger', () async {
    request = '{broken';
    final events = store.events.length;
    await connection.poll();
    expect(connection.error, isNotNull);
    expect(files['result.json'], isNull);
    expect(store.events.length, events);
  });
  test('receipt failure rolls back the entire transaction', () async {
    request = jsonEncode(
      batch([
        operation(entry, {'memo': 'must roll back'}),
      ]),
    );
    final events = store.events.length;
    var writes = 0;
    store.beforeWrite = () {
      if (++writes == 2) throw const LedgerException('receipt write failed');
    };
    await connection.poll();
    expect(files['result.json']!['status'], 'rejected');
    expect(store.events.length, events);
    expect(store.get('entry', entry)!['memo'], '20:14 카카오페이');
    expect(store.local(FileConnection.receiptKey), isNull);
  });
}
