import 'dart:convert';
import 'package:http/http.dart' as http;
import '../data/ledger_store.dart';
import '../domain/value.dart';
import 'google_auth.dart';

abstract interface class ChangeTransport {
  Future<List<Json>> read(String ledger);
  Future<void> write(String ledger, Json event);
}

class SyncEngine {
  final LedgerStore store;
  final ChangeTransport transport;
  bool _running = false;
  SyncEngine(this.store, this.transport);
  Future<void> synchronize() async {
    if (_running) return;
    _running = true;
    try {
      store.merge(await transport.read(store.ledgerId));
      for (final event in store.outbox) {
        await transport.write(store.ledgerId, event);
        store.uploaded(event['id'] as String);
      }
      store.merge(await transport.read(store.ledgerId));
      store.setLocal('last_sync', DateTime.now().toUtc().toIso8601String());
    } finally {
      _running = false;
    }
  }
}

class DriveTransport implements ChangeTransport {
  final GoogleAuth auth;
  final http.Client client;
  final Set<String> Function()? knownChanges;
  DriveTransport(this.auth, {http.Client? client, this.knownChanges})
    : client = client ?? http.Client();
  Future<http.Response> _request(
    String method,
    Uri uri, {
    String? body,
    String contentType = 'application/json',
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await auth.token(refresh: attempt > 0);
      final request = http.Request(method, uri)
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': contentType,
        });
      if (body != null) request.body = body;
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 45)),
      ).timeout(const Duration(seconds: 45));
      if (response.statusCode == 401 && attempt == 0) continue;
      require(
        response.statusCode >= 200 && response.statusCode < 300,
        'Drive 요청 실패 (${response.statusCode}). 연결과 접근 권한을 확인해 주세요.',
      );
      return response;
    }
    throw const LedgerException('Google 로그인이 필요해요.');
  }

  Future<Json> identity() async {
    final response = await _request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/about', {
        'fields': 'user(permissionId,emailAddress,displayName)',
      }),
    );
    return Map<String, dynamic>.from(
      (jsonDecode(response.body) as Json)['user'] as Map,
    );
  }

  Future<List<Json>> _list(String kind, {String? ledger}) async {
    final result = <Json>[];
    String? token;
    do {
      final response = await _request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q':
              "trashed=false and appProperties has { key='app' and value='chagok' } and appProperties has { key='kind' and value='$kind' }${ledger == null ? '' : " and appProperties has { key='ledger' and value='${ledger.replaceAll("'", "\\'")}' }"}",
          'fields': 'nextPageToken,files(id,name,size,appProperties)',
          'pageSize': '1000',
          'pageToken': ?token,
        }),
      );
      final data = jsonDecode(response.body) as Json;
      result.addAll(rows(data['files']));
      token = data['nextPageToken'] as String?;
    } while (token != null);
    return result;
  }

  Future<Json> _download(Json file) async {
    require(
      int.tryParse('${file['size'] ?? 0}')! <= 20 * 1024 * 1024,
      '동기화 파일이 허용 크기를 초과했어요.',
    );
    final response = await _request(
      'GET',
      Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/${Uri.encodeComponent(file['id'] as String)}',
        {'alt': 'media'},
      ),
    );
    require(
      response.bodyBytes.length <= 20 * 1024 * 1024,
      '동기화 파일이 허용 크기를 초과했어요.',
    );
    return jsonDecode(utf8.decode(response.bodyBytes)) as Json;
  }

  Future<List<Json>> ledgers() async {
    final output = <String, Json>{};
    for (final file in await _list('ledger')) {
      final value = await _download(file);
      if (value['format'] == 'chagok-ledger' && value['version'] == 1) {
        output[value['ledger'] as String] = value;
      }
    }
    return output.values.toList();
  }

  Future<void> _upload(
    String name,
    String kind,
    String ledger,
    Json body, {
    String? change,
  }) async {
    final boundary = 'chagok_${uuid.v4()}';
    final metadata = {
      'name': name,
      'parents': ['appDataFolder'],
      'mimeType': 'application/json',
      'appProperties': {
        'app': 'chagok',
        'kind': kind,
        'ledger': ledger,
        'change': ?change,
      },
    };
    final payload =
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${jsonEncode(metadata)}\r\n--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${jsonEncode(body)}\r\n--$boundary--\r\n';
    await _request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id',
      }),
      body: payload,
      contentType: 'multipart/related; boundary=$boundary',
    );
  }

  Future<void> createLedger(String id) =>
      _upload('ledger-$id.json', 'ledger', id, {
        'format': 'chagok-ledger',
        'version': 1,
        'ledger': id,
        'name': '나의 가계부',
        'currency': 'KRW',
        'timezone': 'Asia/Seoul',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
  @override
  Future<List<Json>> read(String ledger) async {
    final events = <Json>[];
    final known = knownChanges?.call() ?? <String>{};
    for (final file in await _list('change', ledger: ledger)) {
      if (known.contains(file['appProperties']['change'])) continue;
      final value = await _download(file);
      require(
        value['ledger'] == ledger &&
            value['id'] == file['appProperties']['change'],
        'Drive 파일의 식별 정보가 일치하지 않아요.',
      );
      events.add(value);
      known.add(value['id'] as String);
    }
    return events;
  }

  @override
  Future<void> write(String ledger, Json event) => _upload(
    'change-${event['id']}.json',
    'change',
    ledger,
    event,
    change: event['id'] as String,
  );
  void close() => client.close();
}
