import 'dart:convert';
import 'package:http/http.dart' as http;
import '../data/ledger_store.dart';
import '../domain/value.dart';
import 'google_auth.dart';

abstract interface class ChangeTransport {
  Future<List<Json>> read(String ledger);
  Future<void> write(String ledger, List<Json> events);
}

class SyncEngine {
  final LedgerStore store;
  final ChangeTransport transport;
  bool _running = false;
  SyncEngine(this.store, this.transport);
  // Bound both request count and payload size; a large event stays indivisible.
  Iterable<List<Json>> _batches(List<Json> events) sync* {
    final ordered = [...events]
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    var batch = <Json>[];
    var bytes = 0;
    for (final event in ordered) {
      final size = utf8.encode(jsonEncode(event)).length + 1;
      if (batch.isNotEmpty &&
          (batch.length >= 200 || bytes + size > 1024 * 1024)) {
        yield batch;
        batch = [];
        bytes = 0;
      }
      batch.add(event);
      bytes += size;
    }
    if (batch.isNotEmpty) yield batch;
  }

  Future<void> synchronize() async {
    if (_running) return;
    _running = true;
    try {
      store.merge(await transport.read(store.ledgerId));
      for (final batch in _batches(store.outbox)) {
        await transport.write(store.ledgerId, batch);
        store.uploaded(batch.map((e) => e['id'] as String));
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
  final String? Function() folderId;
  final String? Function(String)? readCache;
  final void Function(String, String)? writeCache;
  final Map<String, List<String>> _batchChanges = {};
  final Set<String> _remoteBatches = {};
  DriveTransport(
    this.auth, {
    required this.folderId,
    http.Client? client,
    this.knownChanges,
    this.readCache,
    this.writeCache,
  }) : client = client ?? http.Client();

  String get _folder {
    final id = folderId();
    require(
      id != null && id.isNotEmpty && id != 'root',
      '동기화할 Drive 폴더를 선택해 주세요.',
    );
    return id!;
  }

  static String _escape(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

  Future<List<Json>> folders(String parent) => _files(
    "trashed=false and mimeType='application/vnd.google-apps.folder' and 'me' in owners and '${_escape(parent)}' in parents",
    fields: 'id,name,capabilities(canAddChildren)',
    orderBy: 'name',
  );

  Future<Json> folder(String id) async {
    require(id.isNotEmpty && id != 'root', '내 드라이브 안의 폴더를 선택해 주세요.');
    final response = await _request(
      'GET',
      Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/${Uri.encodeComponent(id)}',
        {
          'fields':
              'id,name,mimeType,trashed,ownedByMe,capabilities(canAddChildren)',
        },
      ),
    );
    final value = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    require(
      value['id'] == id &&
          value['mimeType'] == 'application/vnd.google-apps.folder' &&
          value['trashed'] != true &&
          value['ownedByMe'] == true &&
          value['capabilities']?['canAddChildren'] == true,
      '내 Drive에서 파일을 저장할 수 있는 폴더를 선택해 주세요.',
    );
    return value;
  }

  Future<Json> createFolder(String parent, String name) async {
    require(name.trim().isNotEmpty, '폴더 이름을 입력해 주세요.');
    if (parent != 'root') await folder(parent);
    final response = await _request(
      'POST',
      Uri.https('www.googleapis.com', '/drive/v3/files', {'fields': 'id,name'}),
      body: jsonEncode({
        'name': name.trim(),
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parent],
      }),
    );
    return jsonDecode(utf8.decode(response.bodyBytes)) as Json;
  }

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

  Future<List<Json>> _files(
    String query, {
    String fields = 'id,name,size,appProperties',
    String? orderBy,
  }) async {
    final result = <Json>[];
    String? token;
    do {
      final response = await _request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'drive',
          'q': query,
          'fields': 'nextPageToken,files($fields)',
          'orderBy': ?orderBy,
          'pageSize': '1000',
          'pageToken': ?token,
        }),
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
      result.addAll(rows(data['files']));
      token = data['nextPageToken'] as String?;
    } while (token != null);
    return result;
  }

  Future<List<Json>> _list(String kind, {String? ledger}) => _files(
    "trashed=false and '${_escape(_folder)}' in parents and appProperties has { key='app' and value='chagok' } and appProperties has { key='kind' and value='$kind' }${ledger == null ? '' : " and appProperties has { key='ledger' and value='${_escape(ledger)}' }"}",
  );

  Future<Json> _download(Json file) async {
    final size = int.tryParse('${file['size'] ?? 0}');
    require(
      size != null && size >= 0 && size <= 20 * 1024 * 1024,
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
      'parents': [_folder],
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
    _remoteBatches.removeWhere((key) => key.startsWith(_cacheKey(ledger, '')));
    final events = <Json>[];
    final known = {...?knownChanges?.call()};
    final pending = <Json>[];
    for (final file in await _list('change', ledger: ledger)) {
      final id = file['appProperties']?['change'];
      require(id is String && id.isNotEmpty, 'Drive 변경 파일 ID가 없어요.');
      if (known.contains(id)) continue;
      final key = _cacheKey(ledger, id as String);
      var cached = _batchChanges[key];
      if (cached == null && readCache != null) {
        try {
          final raw = readCache!(key);
          if (raw != null) cached = List<String>.from(jsonDecode(raw) as List);
        } catch (_) {
          // A damaged optional cache must never hide actual ledger changes.
        }
      }
      if (cached != null &&
          cached.isNotEmpty &&
          _batchId(cached) == id &&
          cached.every(known.contains)) {
        _remoteBatches.add(key);
        continue;
      }
      pending.add(file);
    }
    // Also accelerate first-time reads of older, individual change files.
    for (var start = 0; start < pending.length; start += 4) {
      final files = pending.skip(start).take(4).toList();
      final values = await Future.wait(files.map(_download));
      for (var i = 0; i < files.length; i++) {
        final value = values[i];
        final id = files[i]['appProperties']['change'] as String;
        require(
          value['ledger'] == ledger && value['id'] == id,
          'Drive 파일의 식별 정보가 일치하지 않아요.',
        );
        List<Json> changes;
        if (value['format'] == 'chagok-changes') {
          require(
            value['version'] == 1 && value['changes'] is List,
            '지원하지 않는 동기화 묶음 형식입니다. 앱을 업데이트해 주세요.',
          );
          changes = rows(value['changes']);
          require(
            changes.isNotEmpty &&
                changes.length <= 200 &&
                changes.every(
                  (e) => e['ledger'] == ledger && e['id'] is String,
                ),
            '동기화 묶음의 변경 기록이 올바르지 않아요.',
          );
          final ids = changes.map((e) => e['id'] as String).toList();
          require(
            ids.toSet().length == ids.length && _batchId(ids) == id,
            '동기화 묶음의 식별 정보가 일치하지 않아요.',
          );
          final key = _cacheKey(ledger, id);
          _batchChanges[key] = ids;
          writeCache?.call(key, jsonEncode(ids));
          _remoteBatches.add(key);
        } else {
          changes = [value];
        }
        // Pass even known events through merge's integrity validation.
        events.addAll(changes);
      }
    }
    return events;
  }

  String _cacheKey(String ledger, String id) =>
      'drive_batch/$_folder/$ledger/$id';
  static String _batchId(List<String> ids) =>
      'batch-${digest([...ids]..sort())}';

  @override
  Future<void> write(String ledger, List<Json> events) async {
    require(
      events.isNotEmpty &&
          events.length <= 200 &&
          events.every((e) => e['ledger'] == ledger && e['id'] is String),
      '업로드할 변경 기록을 확인해 주세요.',
    );
    final ids = events.map((e) => e['id'] as String).toList();
    require(ids.toSet().length == ids.length, '중복 변경 기록이 있어요.');
    final id = _batchId(ids);
    final key = _cacheKey(ledger, id);
    if (_remoteBatches.contains(key)) return;
    final body = <String, dynamic>{
      'format': 'chagok-changes',
      'version': 1,
      'ledger': ledger,
      'id': id,
      'changes': events,
    };
    require(
      utf8.encode(jsonEncode(body)).length <= 20 * 1024 * 1024,
      '동기화 파일이 허용 크기를 초과했어요.',
    );
    await _upload('changes-$id.json', 'change', ledger, body, change: id);
    _batchChanges[key] = ids;
    writeCache?.call(key, jsonEncode(ids));
    _remoteBatches.add(key);
  }

  void close() => client.close();
}
