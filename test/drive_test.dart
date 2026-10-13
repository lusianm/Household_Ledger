import 'dart:convert';
import 'package:chagok/app_controller.dart';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/value.dart';
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
        () => drive.write('ledger', {'id': 'event'}),
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
      await drive.write('ledger', {'id': 'event'});
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
