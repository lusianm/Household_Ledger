import 'dart:convert';
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/domain/ledger_service.dart';
import 'package:chagok/sync/drive_sync.dart';
import 'package:chagok/sync/google_auth.dart';
import 'package:chagok/ui/drive_folder_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class TestAuth extends GoogleAuth {
  @override
  Future<String> token({
    bool interactive = false,
    bool refresh = false,
  }) async => 'test-token';
  @override
  Future<void> disconnect() async {}
}

http.Response response(Json value) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), 200);
Json folder(String id) => {
  'id': id,
  'name': '내 가계부',
  'mimeType': 'application/vnd.google-apps.folder',
  'ownedByMe': true,
  'trashed': false,
  'capabilities': {'canAddChildren': true},
};

void main() {
  LedgerStore ledgerWithEntries(int count) {
    final store = LedgerStore.memory();
    addTearDown(store.close);
    final service = LedgerService(store);
    final account = service.saveAccount(name: '통장', opened: '2026-01-01');
    store.saveBatch([
      for (var i = 0; i < count; i++)
        (
          'entry',
          service.makeEntry(
            type: 'income',
            amount: 100,
            account: account,
            on: '2026-01-01',
            memo: '입금 $i',
            allocations: [service.allocation(100, '기타')],
          ),
        ),
    ]);
    return store;
  }

  DriveTransport connect(BatchDrive server, LedgerStore store) {
    final drive = DriveTransport(
      TestAuth(),
      folderId: () => 'folder',
      client: MockClient(server.handle),
      knownChanges: () => store.events.map((e) => e['id'] as String).toSet(),
      readCache: store.local,
      writeCache: store.setLocal,
    );
    addTearDown(drive.close);
    return drive;
  }

  test(
    'changes upload in one bundle and restart skips already merged bundles',
    () async {
      final source = ledgerWithEntries(16), server = BatchDrive();
      await SyncEngine(source, connect(server, source)).synchronize();
      expect(server.uploads, 1);
      expect(rows(server.bodies.values.single['changes']), hasLength(17));
      expect(source.unsent, 0);
      expect(server.downloads, 0);
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      await SyncEngine(peer, connect(server, peer)).synchronize();
      expect(peer.flow('2026', 'income'), 1600);
      expect(server.downloads, 1);
      final restarted = LedgerStore.memory();
      addTearDown(restarted.close);
      restarted.loadCheckpoint(peer.checkpoint());
      await SyncEngine(restarted, connect(server, restarted)).synchronize();
      expect(server.downloads, 1);
      expect(server.uploads, 1);
      final cacheKey =
          restarted
                  .query(
                    "SELECT key FROM local_settings WHERE key LIKE 'drive_batch/%'",
                  )
                  .single['key']
              as String;
      restarted.setLocal(cacheKey, '[42]');
      await SyncEngine(restarted, connect(server, restarted)).synchronize();
      expect(server.downloads, 2);
      expect(restarted.flow('2026', 'income'), 1600);
    },
  );
  test(
    'lost upload reply retries without another file or duplicate records',
    () async {
      final source = ledgerWithEntries(16),
          server = BatchDrive()..loseReply = true;
      final sync = SyncEngine(source, connect(server, source));
      await expectLater(sync.synchronize(), throwsA(isA<LedgerException>()));
      expect(source.unsent, 17);
      await sync.synchronize();
      expect(source.unsent, 0);
      expect(server.uploads, 1);
      expect(source.all('entry'), hasLength(16));
    },
  );
  test(
    'lost chunk reply remains idempotent after checkpoint restart',
    () async {
      final source = ledgerWithEntries(220),
          server = BatchDrive()..loseReply = true;
      await expectLater(
        SyncEngine(source, connect(server, source)).synchronize(),
        throwsA(isA<LedgerException>()),
      );
      final restarted = LedgerStore.memory();
      addTearDown(restarted.close);
      restarted.loadCheckpoint(source.checkpoint());
      await SyncEngine(restarted, connect(server, restarted)).synchronize();
      expect(restarted.unsent, 0);
      expect(server.uploads, 2);
      expect(server.bodies, hasLength(2));
      expect(restarted.flow('2026', 'income'), 22000);
    },
  );
  test(
    'large Korean records split by UTF-8 size before the count limit',
    () async {
      final source = ledgerWithEntries(0), server = BatchDrive();
      final service = LedgerService(source);
      final account = source.all('account').single['id'] as String;
      source.saveBatch([
        for (var i = 0; i < 20; i++)
          (
            'entry',
            service.makeEntry(
              type: 'income',
              amount: 1,
              account: account,
              on: '2026-01-01',
              memo: List.filled(19000, '가').join(),
              allocations: [service.allocation(1, '기타')],
            ),
          ),
      ]);
      await SyncEngine(source, connect(server, source)).synchronize();
      expect(server.uploads, greaterThan(1));
      expect(
        server.bodies.values.expand((v) => rows(v['changes'])),
        hasLength(21),
      );
      for (final body in server.bodies.values) {
        expect(
          utf8.encode(jsonEncode(body)).length,
          lessThan(1024 * 1024 + 512),
        );
      }
      expect(source.unsent, 0);
    },
  );
  test(
    'legacy downloads use bounded concurrency and finish before merge',
    () async {
      final source = ledgerWithEntries(8), server = BatchDrive();
      for (final event in source.events) {
        server.add({
          'change': event['id'],
          'ledger': source.ledgerId,
          'kind': 'change',
          'app': 'chagok',
        }, event);
      }
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      await SyncEngine(peer, connect(server, peer)).synchronize();
      expect(server.maxDownloads, 4);
      expect(server.downloads, 9);
      expect(peer.flow('2026', 'income'), 800);
    },
  );
  test('partial upload failure acknowledges only completed chunks', () async {
    final source = ledgerWithEntries(400),
        server = BatchDrive()..failUpload = 2;
    final sync = SyncEngine(source, connect(server, source));
    await expectLater(sync.synchronize(), throwsA(isA<LedgerException>()));
    expect(source.unsent, 201);
    expect(server.bodies.length, 1);
    await sync.synchronize();
    expect(source.unsent, 0);
    expect(server.bodies.values.map((v) => rows(v['changes']).length), [
      200,
      200,
      1,
    ]);
    final peer = LedgerStore.memory(ledger: source.ledgerId);
    addTearDown(peer.close);
    await SyncEngine(peer, connect(server, peer)).synchronize();
    expect(peer.flow('2026', 'income'), 40000);
    expect(peer.pending, isEmpty);
  });
  test(
    'legacy files and duplicate bundles merge without duplicating balances',
    () async {
      final source = ledgerWithEntries(2), server = BatchDrive();
      final account = source.events.firstWhere((e) => e['kind'] == 'account');
      server.add({
        'change': account['id'],
        'ledger': source.ledgerId,
        'kind': 'change',
        'app': 'chagok',
      }, account);
      await SyncEngine(source, connect(server, source)).synchronize();
      final batch = server.bodies.values.firstWhere(
        (v) => v['format'] == 'chagok-changes',
      );
      server.add({
        'change': batch['id'],
        'ledger': source.ledgerId,
        'kind': 'change',
        'app': 'chagok',
      }, batch);
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      await SyncEngine(peer, connect(server, peer)).synchronize();
      expect(peer.events, hasLength(3));
      expect(peer.flow('2026', 'income'), 200);
    },
  );
  test(
    'corrupt bundle is atomic and cached IDs cannot hide a failed merge',
    () async {
      final source = ledgerWithEntries(2), server = BatchDrive();
      await SyncEngine(source, connect(server, source)).synchronize();
      final body = server.bodies.values.single;
      (body['changes'] as List).first['data']['memo'] = 'tampered';
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      final sync = SyncEngine(peer, connect(server, peer));
      await expectLater(sync.synchronize(), throwsA(isA<LedgerException>()));
      expect(peer.events, isEmpty);
      await expectLater(sync.synchronize(), throwsA(isA<LedgerException>()));
      expect(server.downloads, 2);
      expect(peer.events, isEmpty);
    },
  );
  test(
    'bundled concurrent edits retain conflict history on both devices',
    () async {
      final source = ledgerWithEntries(1), server = BatchDrive();
      final left = connect(server, source);
      await SyncEngine(source, left).synchronize();
      final peer = LedgerStore.memory(ledger: source.ledgerId);
      addTearDown(peer.close);
      final right = connect(server, peer);
      await SyncEngine(peer, right).synchronize();
      source.save('entry', {...source.all('entry').single, 'memo': 'PC 수정'});
      peer.save('entry', {...peer.all('entry').single, 'memo': '휴대폰 수정'});
      await SyncEngine(source, left).synchronize();
      await SyncEngine(peer, right).synchronize();
      await SyncEngine(source, left).synchronize();
      expect(source.conflicts.keys, peer.conflicts.keys);
      expect(source.conflicts, isNotEmpty);
      expect(source.flow('2026', 'income'), 100);
      expect(peer.flow('2026', 'income'), 100);
    },
  );
  test(
    'missing folder never falls back to app data or another destination',
    () async {
      final drive = DriveTransport(
        TestAuth(),
        folderId: () => null,
        client: MockClient(
          (_) async => throw StateError('Unexpected network request'),
        ),
      );
      addTearDown(drive.close);
      expect(() => drive.read('ledger'), throwsA(isA<LedgerException>()));
      expect(
        () => drive.createLedger('ledger'),
        throwsA(isA<LedgerException>()),
      );
      expect(
        () => drive.write('ledger', [
          {'id': 'event', 'ledger': 'ledger'},
        ]),
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test(
    'folder browsing is paginated, owned by signed-in user, and preserves Korean names',
    () async {
      var calls = 0;
      final drive = DriveTransport(
        TestAuth(),
        folderId: () => null,
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer test-token');
          final params = request.url.queryParameters;
          expect(params['spaces'], 'drive');
          expect(params['q'], contains("'root' in parents"));
          expect(params['q'], contains("'me' in owners"));
          calls++;
          if (calls == 1) {
            return response({
              'nextPageToken': 'page2',
              'files': [folder('first')],
            });
          }
          expect(params['pageToken'], 'page2');
          return response({
            'files': [folder('second')],
          });
        }),
      );
      addTearDown(drive.close);
      final files = await drive.folders('root');
      expect(files.map((f) => f['id']), ['first', 'second']);
      expect(files.first['name'], '내 가계부');
    },
  );
  test('selection rejects foreign, trashed, and read-only folders', () async {
    Json result = folder('selected');
    final drive = DriveTransport(
      TestAuth(),
      folderId: () => null,
      client: MockClient((_) async => response(result)),
    );
    addTearDown(drive.close);
    expect((await drive.folder('selected'))['id'], 'selected');
    for (final invalid in [
      {...folder('selected'), 'ownedByMe': false},
      {...folder('selected'), 'trashed': true},
      {
        ...folder('selected'),
        'capabilities': {'canAddChildren': false},
      },
      {...folder('selected'), 'mimeType': 'application/json'},
    ]) {
      result = invalid;
      await expectLater(
        drive.folder('selected'),
        throwsA(isA<LedgerException>()),
      );
    }
  });
  test(
    'ledger queries and uploads stay in selected folder and ignore unrelated documents',
    () async {
      String selected = 'folder-a';
      final parents = <String>[];
      final drive = DriveTransport(
        TestAuth(),
        folderId: () => selected,
        client: MockClient((request) async {
          if (request.method == 'GET') {
            expect(
              request.url.queryParameters['q'],
              contains("'$selected' in parents"),
            );
            expect(
              request.url.queryParameters['q'],
              contains("key='app' and value='chagok'"),
            );
            return response({'files': []});
          }
          final metadata =
              jsonDecode(request.body.split('\r\n\r\n')[1].split('\r\n--')[0])
                  as Json;
          parents.add((metadata['parents'] as List).single as String);
          return response({'id': 'uploaded'});
        }),
      );
      addTearDown(drive.close);
      await drive.read('ledger');
      await drive.createLedger('ledger');
      selected = 'folder-b';
      await drive.read('ledger');
      await drive.write('ledger', [
        {'id': 'event', 'ledger': 'ledger'},
      ]);
      expect(parents, ['folder-a', 'folder-b']);
    },
  );
  test(
    'changing destination resends history; an unexpected account blocks all ledger traffic',
    () async {
      final store = LedgerStore.memory();
      final auth = TestAuth();
      var owner = 'user-a';
      final uploads = <String>[];
      var lists = 0;
      final drive = DriveTransport(
        auth,
        folderId: () => store.local('drive_folder_id'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/about')) {
            return response({
              'user': {
                'permissionId': owner,
                'emailAddress': '$owner@example.com',
              },
            });
          }
          if (request.url.path.startsWith('/drive/v3/files/')) {
            return response(folder(request.url.pathSegments.last));
          }
          if (request.method == 'GET') {
            lists++;
            return response({'files': []});
          }
          final metadata =
              jsonDecode(request.body.split('\r\n\r\n')[1].split('\r\n--')[0])
                  as Json;
          uploads.add((metadata['parents'] as List).single as String);
          return response({'id': 'uploaded'});
        }),
      );
      final app = AppController(store, '.', auth: auth, drive: drive);
      addTearDown(() {
        app.dispose();
        store.close();
      });
      app.service.saveAccount(name: '생활비', opening: 10000);
      // Legacy app-data connections must not resume without folder selection.
      store.setLocal('drive_owner', owner);
      expect(app.connected, isFalse);
      await app.bind({'permissionId': owner}, folder('folder-a'));
      expect(store.unsent, 0);
      await app.disconnect();
      owner = 'user-b';
      await app.bind({'permissionId': owner}, folder('folder-b'));
      expect(uploads, ['folder-a', 'folder-b']);
      final before = lists;
      owner = 'unexpected-user';
      await app.sync();
      expect(app.syncError, contains('Google 계정이 달라요'));
      expect(lists, before);
      expect(uploads.length, 2);
      expect(store.all('account').single['opening'], 10000);
    },
  );
  testWidgets(
    'narrow folder picker navigates and confirms the actual folder ID',
    (tester) async {
      tester.view.physicalSize = const Size(344, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Json? selected;
      final drive = DriveTransport(
        TestAuth(),
        folderId: () => null,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/files/personal')) {
            return response(folder('personal'));
          }
          return response({
            'files':
                request.url.queryParameters['q']!.contains("'root' in parents")
                ? [folder('personal')]
                : [],
          });
        }),
      );
      addTearDown(drive.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<Json>(
                    context: context,
                    builder: (_) => DriveFolderPicker(
                      drive: drive,
                      email: 'me@example.com',
                    ),
                  );
                },
                child: const Text('폴더 열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('폴더 열기'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '이 폴더 선택'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('내 가계부'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('이 폴더 선택'));
      await tester.pumpAndSettle();
      expect(selected?['id'], 'personal');
      expect(tester.takeException(), isNull);
    },
  );
}

class BatchDrive {
  final files = <Json>[];
  final bodies = <String, Json>{};
  int uploads = 0, downloads = 0;
  int activeDownloads = 0, maxDownloads = 0;
  int? failUpload;
  bool loseReply = false;
  void add(Json properties, Json body) {
    final id = 'file-${files.length}';
    files.add({
      'id': id,
      'size': '${utf8.encode(jsonEncode(body)).length}',
      'appProperties': properties,
    });
    bodies[id] = copyJson(body);
  }

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'GET') {
      if (request.url.queryParameters['alt'] == 'media') {
        downloads++;
        activeDownloads++;
        if (activeDownloads > maxDownloads) maxDownloads = activeDownloads;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return response(bodies[request.url.pathSegments.last]!);
        } finally {
          activeDownloads--;
        }
      }
      return response({'files': files});
    }
    uploads++;
    if (uploads == failUpload) return http.Response('temporary failure', 503);
    final parts = request.body.split('\r\n\r\n');
    final metadata = jsonDecode(parts[1].split('\r\n--')[0]) as Json;
    final body = jsonDecode(parts[2].split('\r\n--')[0]) as Json;
    add(Map<String, dynamic>.from(metadata['appProperties'] as Map), body);
    if (loseReply) {
      loseReply = false;
      return http.Response('reply lost', 503);
    }
    return response({'id': files.last['id']});
  }
}
