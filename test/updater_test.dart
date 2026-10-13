import 'dart:convert';
import 'dart:io';
import 'package:chagok/data/ledger_store.dart';
import 'package:chagok/domain/value.dart';
import 'package:chagok/updates/app_updater.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late LedgerStore store;
  late Directory directory;
  late AppUpdater updater;
  final bytes = utf8.encode('verified installer fixture');
  Json release({String tag = 'v0.2.0+2', String? hash, String? url}) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'body': '새 버전',
    'assets': [
      {
        'name': 'chagok-windows-setup.exe',
        'browser_download_url':
            url ??
            'https://github.com/example/chagok/releases/download/$tag/chagok-windows-setup.exe',
        'digest': hash ?? 'sha256:${sha256.convert(bytes)}',
        'size': bytes.length,
      },
    ],
  };
  AppUpdater create(http.Client client, {bool enabled = true}) => AppUpdater(
    store,
    directory.path,
    current: const AppVersion(0, 1, 0, 1),
    platform: 'windows',
    repository: 'example/chagok',
    enabled: enabled,
    client: client,
  );
  setUp(() async {
    store = LedgerStore.memory();
    directory = await Directory.systemTemp.createTemp('chagok-updater-');
    updater = create(
      MockClient(
        (_) async =>
            http.Response.bytes(utf8.encode(jsonEncode(release())), 200),
      ),
    );
  });
  tearDown(() async {
    updater.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  test('versions compare numerically and never offer a build downgrade', () {
    expect(
      AppVersion.parse('v0.10.0+10').compareTo(AppVersion.parse('0.9.0+9')),
      greaterThan(0),
    );
    expect(updater.parseRelease(release(tag: 'v0.1.0+1')), isNull);
    expect(updater.parseRelease(release(tag: 'v0.2.0+1')), isNull);
    expect(updater.parseRelease(release(tag: 'v0.0.9+9')), isNull);
    expect(updater.parseRelease({...release(), 'draft': true}), isNull);
    expect(updater.parseRelease({...release(), 'prerelease': true}), isNull);
    expect(updater.parseRelease(release(tag: 'v0.1.0+2')), isNotNull);
  });
  test('rejects untrusted asset URLs and missing checksums', () {
    for (final url in [
      'http://github.com/example/chagok/releases/download/v0.2.0+2/chagok-windows-setup.exe',
      'https://github.com/other/chagok/releases/download/v0.2.0+2/chagok-windows-setup.exe',
      'https://github.com.example.org/example/chagok/releases/download/v0.2.0+2/chagok-windows-setup.exe',
    ]) {
      expect(
        () => updater.parseRelease(release(url: url)),
        throwsA(isA<LedgerException>()),
      );
    }
    expect(
      () => updater.parseRelease(release(hash: '')),
      throwsA(isA<LedgerException>()),
    );
  });
  test(
    'checks daily, retains metadata across restart, and supports manual checks',
    () async {
      var calls = 0;
      updater.dispose();
      updater = create(
        MockClient((request) async {
          calls++;
          expect(request.url.path, '/repos/example/chagok/releases/latest');
          return http.Response.bytes(utf8.encode(jsonEncode(release())), 200);
        }),
      );
      await updater.check();
      await updater.check();
      expect(calls, 1);
      expect(updater.showBanner, isTrue);
      updater.dismiss();
      expect(updater.showBanner, isFalse);
      updater.dispose();
      updater = create(
        MockClient((_) async {
          calls++;
          return http.Response('', 404);
        }),
      );
      expect(updater.available?.version.toString(), '0.2.0+2');
      expect(updater.showBanner, isFalse);
      updater.setAutomatic(false);
      await updater.check();
      expect(calls, 1);
      await updater.check(force: true);
      expect(calls, 2);
      expect(updater.available, isNull);
    },
  );
  test('debug builds do not check releases even on manual request', () async {
    updater.dispose();
    updater = create(
      MockClient((_) async => throw StateError('Must not request')),
      enabled: false,
    );
    await updater.check(force: true);
    expect(updater.error, isNull);
    expect(updater.available, isNull);
  });
  test(
    'network failure preserves the ledger and allows explicit retry',
    () async {
      final ledger = store.ledgerId;
      updater.dispose();
      var calls = 0;
      updater = create(
        MockClient((_) async {
          calls++;
          if (calls == 1) throw const SocketException('offline');
          return http.Response.bytes(utf8.encode(jsonEncode(release())), 200);
        }),
      );
      await updater.check();
      expect(updater.error, isNotNull);
      expect(store.ledgerId, ledger);
      await updater.check(force: true);
      expect(updater.error, isNull);
      expect(updater.available, isNotNull);
    },
  );
  test(
    'verifies installer and reuses the verified download on retry',
    () async {
      var downloads = 0;
      updater.dispose();
      updater = create(
        MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response.bytes(utf8.encode(jsonEncode(release())), 200);
          }
          downloads++;
          return http.Response.bytes(bytes, 200);
        }),
      );
      await updater.check();
      final file = await updater.download();
      expect(await file.readAsBytes(), bytes);
      expect((await updater.download()).path, file.path);
      expect(downloads, 1);
      expect(updater.progress, 1);
    },
  );
  test(
    'corrupt, truncated, and oversized installers never become executable',
    () async {
      for (final badBytes in [
        List.filled(bytes.length, 0),
        bytes.sublist(1),
        [...bytes, 0],
      ]) {
        updater.dispose();
        updater = create(
          MockClient((request) async {
            if (request.url.host == 'api.github.com') {
              return http.Response.bytes(
                utf8.encode(jsonEncode(release())),
                200,
              );
            }
            return http.Response.bytes(badBytes, 200);
          }),
        );
        await updater.check(force: true);
        await expectLater(updater.download(), throwsA(isA<LedgerException>()));
        expect(
          await Directory('${directory.path}/updates').list().toList(),
          isEmpty,
        );
        expect(updater.downloading, isFalse);
      }
    },
  );
}
