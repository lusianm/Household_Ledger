import 'dart:async';
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/sync/drive_sync.dart';
import 'package:chagok/sync/google_auth.dart';
import 'package:flutter_test/flutter_test.dart';

class Auth extends GoogleAuth {
  int calls = 0;
  final List<bool> interactiveCalls = [];
  @override
  Future<String> token({bool interactive = false, bool refresh = false}) async {
    calls++;
    interactiveCalls.add(interactive);
    return 'test';
  }
}

class Drive extends DriveTransport {
  int reads = 0;
  Drive(super.auth) : super(folderId: () => 'folder');
  @override
  Future<Json> identity() async => {'permissionId': 'owner'};
  @override
  Future<Json> folder(String id) async => {'id': id, 'name': '내 폴더'};
  @override
  Future<List<Json>> read(String ledger) async {
    reads++;
    return [];
  }

  @override
  Future<void> write(String ledger, List<Json> changes) async {}
}

void main() {
  test(
    'device checkpoint preserves account balance, category strings, local draft and delivery state',
    () {
      final source = LedgerStore.memory(), restored = LedgerStore.memory();
      addTearDown(source.close);
      addTearDown(restored.close);
      final service = LedgerService(source);
      final account = service.saveAccount(name: '생활비', opening: 100000);
      source.uploaded([source.events.single['id'] as String]);
      service.saveEntry(
        service.makeEntry(
          type: 'expense',
          amount: 9000,
          account: account,
          on: '2026-10-13',
          allocations: [service.allocation(9000, '식비', subcategory: '카페')],
        ),
      );
      source.setLocal('entry_draft', '{"memo":"임시 메모"}');
      source.setLocal('drive_folder_id', 'folder');
      restored.loadCheckpoint(source.checkpoint());
      expect(restored.balance(account), 91000);
      expect(restored.deviceId, source.deviceId);
      expect(restored.ledgerId, source.ledgerId);
      expect(restored.unsent, 1);
      expect(restored.local('entry_draft'), contains('임시 메모'));
      expect(
        restored
            .query(
              'SELECT category_name,subcategory_name FROM transaction_allocations',
            )
            .single,
        {'category_name': '식비', 'subcategory_name': '카페'},
      );
    },
  );
  test(
    'device checkpoints retain unresolved conflicts, unlike user backup restore',
    () {
      final source = LedgerStore.memory(), restored = LedgerStore.memory();
      addTearDown(source.close);
      addTearDown(restored.close);
      final service = LedgerService(source);
      final id = service.saveAccount(name: '통장', opening: 10000);
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      peer.merge(source.events);
      source.save('account', {...source.get('account', id)!, 'name': '기기 A'});
      peer.save('account', {...peer.get('account', id)!, 'name': '기기 B'});
      source.merge(peer.events);
      expect(source.conflicts, isNotEmpty);
      restored.loadCheckpoint(source.checkpoint());
      expect(restored.conflicts.keys, source.conflicts.keys);
      expect(restored.balance(id), 10000);
    },
  );
  test(
    'write failure blocks mutations until successful retry and preserves the unsaved record',
    () async {
      final store = LedgerStore.memory();
      var fail = true;
      Json? written;
      final app = AppController(
        store,
        '.',
        checkpointWriter: (snapshot) async {
          if (fail) throw StateError('disk full');
          written = snapshot;
        },
      );
      addTearDown(() {
        app.dispose();
        store.close();
      });
      final id = app.service.saveAccount(name: '생활비', opening: 10000);
      await expectLater(app.flush(), throwsA(isA<LedgerException>()));
      expect(app.storageError, contains('disk full'));
      expect(app.dirty, isTrue);
      expect(
        () => app.service.saveAccount(name: '추가 통장'),
        throwsA(isA<LedgerException>()),
      );
      fail = false;
      await app.retryStorage();
      expect(app.storageError, isNull);
      expect(app.dirty, isFalse);
      final recovered = LedgerStore.memory();
      addTearDown(recovered.close);
      recovered.loadCheckpoint(written!);
      expect(recovered.balance(id), 10000);
      expect(recovered.all('account'), hasLength(1));
    },
  );
  test(
    'edits arriving during a write drain in order and flush waits for the final snapshot',
    () async {
      final store = LedgerStore.memory();
      final block = Completer<void>();
      final entered = Completer<void>();
      final snapshots = <Json>[];
      final app = AppController(
        store,
        '.',
        checkpointWriter: (value) async {
          snapshots.add(value);
          if (snapshots.length == 1) {
            entered.complete();
            await block.future;
          }
        },
      );
      addTearDown(() {
        app.dispose();
        store.close();
      });
      app.service.saveAccount(name: '하나');
      final flush = app.flush();
      await entered.future;
      app.service.saveAccount(name: '둘');
      block.complete();
      await flush;
      expect(snapshots, hasLength(2));
      expect(app.dirty, isFalse);
      final recovered = LedgerStore.memory();
      addTearDown(recovered.close);
      recovered.loadCheckpoint(snapshots.last);
      expect(recovered.all('account'), hasLength(2));
    },
  );
  test(
    'only first launch and manual button synchronize; edits and resume do not',
    () async {
      final store = LedgerStore.memory();
      final auth = Auth();
      final drive = Drive(auth);
      store.setLocal('drive_owner', 'owner');
      store.setLocal('drive_folder_id', 'folder');
      final app = AppController(store, '.', auth: auth, drive: drive);
      addTearDown(() {
        app.dispose();
        store.close();
      });
      await app.resume();
      final reads = drive.reads;
      expect(reads, greaterThan(0));
      app.service.saveAccount(name: '새 계좌');
      app.changed();
      await app.resume();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drive.reads, reads);
      expect(store.unsent, 1);
      await app.sync(interactive: true);
      expect(drive.reads, greaterThan(reads));
      expect(auth.interactiveCalls, [false, true]);
      expect(store.unsent, 0);
    },
  );
}
