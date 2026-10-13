import 'dart:convert';
import 'package:sqlite3/common.dart';
import 'database_native.dart'
    if (dart.library.js_interop) 'database_web.dart'
    as backend;
import '../domain/value.dart';
import '../domain/validation.dart';

/// Immutable revisions are the sync source; SQL tables are an atomic projection.
/// Revision parents, never device clocks, determine the visible version.
class LedgerStore {
  final CommonDatabase db;
  void Function()? onChanged;
  void Function()? beforeWrite;
  late String ledgerId;
  late String deviceId;
  final Map<String, Json> _documents = {};
  final Map<String, List<String>> _heads = {};
  final Map<String, List<Json>> conflicts = {};
  final List<String> pending = [];
  bool _closed = false;

  LedgerStore(String path) : db = backend.openDatabase(path) {
    _open();
  }
  LedgerStore.memory({String? ledger}) : db = backend.openDatabase(null) {
    _open();
    if (ledger != null) {
      ledgerId = ledger;
      setLocal('ledger_id', ledger);
    }
  }
  void _open() {
    db.execute(
      'PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS local_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    final version = db.select('PRAGMA user_version').first.values.first as int;
    require(version <= 1, '더 최신 버전에서 만든 가계부입니다. 앱을 업데이트해 주세요.');
    db.execute(
      'CREATE TABLE IF NOT EXISTS change_events (id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_id TEXT NOT NULL, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS change_entity ON change_events(kind,entity_id)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS sync_deliveries (id TEXT PRIMARY KEY, uploaded INTEGER NOT NULL DEFAULT 0)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS aggregates (kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(kind,id))',
    );
    for (final entry in schema.entries) {
      db.execute('CREATE TABLE IF NOT EXISTS ${entry.key} (${entry.value})');
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS postings_account ON postings(account_id); CREATE INDEX IF NOT EXISTS transaction_date ON transactions(date); PRAGMA user_version=1;',
    );
    ledgerId = local('ledger_id') ?? uuid.v4();
    deviceId = local('device_id') ?? uuid.v4();
    setLocal('ledger_id', ledgerId);
    setLocal('device_id', deviceId);
    _rebuild();
  }

  String? local(String key) {
    final list = db.select('SELECT value FROM local_settings WHERE key=?', [
      key,
    ]);
    return list.isEmpty ? null : list.first['value'] as String;
  }

  void setLocal(String key, String value) {
    if (local(key) == value) return;
    beforeWrite?.call();
    db.execute('INSERT OR REPLACE INTO local_settings VALUES (?,?)', [
      key,
      value,
    ]);
    onChanged?.call();
  }

  void removeLocal(String key) {
    if (local(key) == null) return;
    beforeWrite?.call();
    db.execute('DELETE FROM local_settings WHERE key=?', [key]);
    onChanged?.call();
  }

  List<Json> all(String kind, {bool deleted = false}) =>
      _documents.entries
          .where(
            (e) =>
                e.key.startsWith('$kind/') &&
                (deleted || e.value['deleted'] != true),
          )
          .map((e) => copyJson(e.value))
          .toList()
        ..sort(
          (a, b) => '${a['name'] ?? a['date'] ?? a['id']}'.compareTo(
            '${b['name'] ?? b['date'] ?? b['id']}',
          ),
        );
  Json? get(String kind, String id) {
    final value = _documents['$kind/$id'];
    return value == null ? null : copyJson(value);
  }

  List<Json> query(String sql, [List<Object?> parameters = const []]) => db
      .select(sql, parameters)
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
  List<Json> get events => query(
    'SELECT body FROM change_events ORDER BY id',
  ).map((r) => jsonDecode(r['body'] as String) as Json).toList();
  int get unsent =>
      query(
            'SELECT COUNT(*) n FROM sync_deliveries WHERE uploaded=0',
          ).first['n']
          as int;
  List<Json> get outbox => query(
    'SELECT body FROM change_events JOIN sync_deliveries USING(id) WHERE uploaded=0',
  ).map((r) => jsonDecode(r['body'] as String) as Json).toList();
  void uploaded(String id) {
    db.execute('UPDATE sync_deliveries SET uploaded=1 WHERE id=?', [id]);
    onChanged?.call();
  }

  static String eventId(Json e) => digest({
    'schema': 1,
    'ledger': e['ledger'],
    'kind': e['kind'],
    'entity': e['entity'],
    'parents': e['parents'],
    'data': e['data'],
  });
  Json _event(String kind, Json data, List<String> parents) {
    final sortedParents = [...parents]..sort();
    final e = <String, dynamic>{
      'schema': 1,
      'ledger': ledgerId,
      'kind': kind,
      'entity': data['id'],
      'parents': sortedParents,
      'data': copyJson(data),
      'device': deviceId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    e['id'] = eventId(e);
    return e;
  }

  void save(String kind, Json data, {bool resolve = false}) =>
      saveBatch([(kind, data)], resolve: resolve);
  void saveBatch(List<(String, Json)> changes, {bool resolve = false}) {
    final existingPending = pending.toSet();
    final batch = <Json>[];
    for (final (kind, data) in changes) {
      final key = '$kind/${data['id']}';
      require(
        resolve || !conflicts.containsKey(key),
        '이 기록은 동기화 충돌을 먼저 해결해 주세요.',
      );
      validateDocument(kind, data);
      batch.add(_event(kind, data, _heads[key] ?? []));
    }
    _transaction(() {
      for (final e in batch) {
        _insert(e, uploaded: false);
      }
      _rebuild();
      require(
        pending.every(existingPending.contains),
        '연결된 계좌·정기 규칙을 확인해 주세요. ${pending.take(2).join(', ')}',
      );
    });
  }

  void resolve(String key, Json data) =>
      save(key.split('/').first, data, resolve: true);
  void remove(String kind, String id) {
    final data = get(kind, id);
    require(data != null, '기록을 찾을 수 없어요.');
    if (kind == 'entry') {
      require(
        rows(data!['receipts']).where((r) => r['voided'] != true).isEmpty,
        '수령 내역을 먼저 취소해 주세요.',
      );
      require(
        rows(data['refunds']).where((r) => r['voided'] != true).isEmpty,
        '환불 내역을 먼저 취소해 주세요.',
      );
    }
    save(kind, {...data!, 'deleted': true});
  }

  void merge(List<Json> incoming) {
    // Validate the complete transport batch before touching the database.
    final known = {for (final e in events) e['id'] as String: e};
    for (final e in incoming) {
      require(
        e['schema'] == 1 && e['ledger'] == ledgerId,
        '다른 가계부 또는 지원하지 않는 동기화 형식입니다.',
      );
      require(
        e['id'] is String && e['id'] == eventId(e),
        '동기화 파일의 무결성 검사가 실패했어요.',
      );
      require(
        e['parents'] is List &&
            (e['parents'] as List).every((p) => p is String),
        '변경 버전 형식이 올바르지 않아요.',
      );
      require(
        e['data'] is Map && e['entity'] == e['data']['id'],
        '기록 식별자가 일치하지 않아요.',
      );
      validateDocument(
        e['kind'] as String,
        Map<String, dynamic>.from(e['data'] as Map),
      );
      known[e['id'] as String] = e;
    }
    for (final e in incoming) {
      for (final parent in e['parents'] as List) {
        final p = known[parent];
        require(
          p == null || (p['kind'] == e['kind'] && p['entity'] == e['entity']),
          '서로 다른 기록의 버전이 연결되어 있어요.',
        );
      }
    }
    _transaction(() {
      for (final e in incoming) {
        _insert(e, uploaded: true);
      }
      _rebuild();
    });
  }

  void _insert(Json event, {required bool uploaded}) {
    db.execute('INSERT OR IGNORE INTO change_events VALUES (?,?,?,?)', [
      event['id'],
      event['kind'],
      event['entity'],
      jsonEncode(event),
    ]);
    db.execute('INSERT OR IGNORE INTO sync_deliveries VALUES (?,?)', [
      event['id'],
      uploaded ? 1 : 0,
    ]);
  }

  void _transaction(void Function() action) {
    beforeWrite?.call();
    db.execute('BEGIN IMMEDIATE');
    try {
      action();
      db.execute('COMMIT');
      onChanged?.call();
    } catch (_) {
      db.execute('ROLLBACK');
      _rebuild();
      rethrow;
    }
  }

  void _rebuild() {
    _documents.clear();
    _heads.clear();
    conflicts.clear();
    pending.clear();
    final groups = <String, Map<String, Json>>{};
    for (final event in events) {
      (groups['${event['kind']}/${event['entity']}'] ??= {})[event['id']
              as String] =
          event;
    }
    for (final group in groups.entries) {
      final valid = <String, Json>{};
      var progress = true;
      while (progress) {
        progress = false;
        for (final e in group.value.entries) {
          if (!valid.containsKey(e.key) &&
              (e.value['parents'] as List).every(valid.containsKey)) {
            valid[e.key] = e.value;
            progress = true;
          }
        }
      }
      if (valid.length != group.value.length) {
        pending.add('${group.key}: 이전 변경 수신 대기');
      }
      if (valid.isEmpty) continue;
      final parentIds = valid.values
          .expand((e) => (e['parents'] as List).cast<String>())
          .toSet();
      final heads = valid.keys.where((id) => !parentIds.contains(id)).toList()
        ..sort();
      _heads[group.key] = heads;
      Json? visible;
      if (heads.map((id) => digest(valid[id]!['data'])).toSet().length == 1) {
        visible = valid[heads.first];
      } else {
        Set<String> ancestors(String id) {
          final found = <String>{};
          final stack = [id];
          while (stack.isNotEmpty) {
            final next = stack.removeLast();
            if (found.add(next)) {
              stack.addAll((valid[next]!['parents'] as List).cast<String>());
            }
          }
          return found;
        }

        var common = ancestors(heads.first);
        for (final id in heads.skip(1)) {
          common = common.intersection(ancestors(id));
        }
        final bases = common
            .where(
              (id) => !common.any(
                (other) => other != id && ancestors(other).contains(id),
              ),
            )
            .toList();
        if (bases.length == 1) visible = valid[bases.single];
        conflicts[group.key] = heads.map((id) => valid[id]!).toList();
      }
      if (visible != null) {
        _documents[group.key] = copyJson(visible['data'] as Json);
      }
    }
    _project();
  }

  void _put(String table, Json row) {
    final keys = row.keys.toList();
    db.execute(
      'INSERT OR REPLACE INTO $table (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
      keys.map((k) => row[k] as Object?).toList(),
    );
  }

  void _project() {
    for (final table in schema.keys.toList().reversed) {
      db.execute('DELETE FROM $table');
    }
    db.execute('DELETE FROM aggregates');
    for (final item in _documents.entries) {
      final slash = item.key.indexOf('/');
      db.execute('INSERT INTO aggregates VALUES (?,?,?)', [
        item.key.substring(0, slash),
        item.value['id'],
        jsonEncode(item.value),
      ]);
    }
    final accounts = all('account', deleted: true);
    final accountIds = accounts.map((a) => a['id']).toSet();
    for (final a in accounts) {
      _put('accounts', {
        'id': a['id'],
        'name': a['name'],
        'kind': a['kind'],
        'is_liquid': a['liquid'] == true ? 1 : 0,
        'is_archived': a['archived'] == true ? 1 : 0,
      });
      if (a['opening'] != 0) {
        _transactionRows({
          'id': 'opening:${a['id']}',
          'date': a['date'],
          'type': 'opening',
          'amount': (a['opening'] as int).abs(),
          'memo': '초기 잔액',
          'account': a['id'],
          'postings': [
            {'account': a['id'], 'delta': a['opening']},
          ],
        });
      }
    }
    for (final c in all('category', deleted: true)) {
      _put('categories', {
        'id': c['id'],
        'type': c['type'],
        'parent_id': c['parent'],
        'name': c['name'],
        'deleted': c['deleted'] == true ? 1 : 0,
      });
    }
    for (final b in all('budget')) {
      _put('budgets', {
        'id': b['id'],
        'month': b['month'],
        'category_id': b['category'],
        'amount': b['amount'],
      });
    }
    for (final rule in all('rule', deleted: true)) {
      _put('recurring_rules', {
        'id': rule['id'],
        'status': rule['deleted'] == true
            ? 'deleted'
            : rule['paused'] == true
            ? 'paused'
            : 'active',
        'body': jsonEncode(rule),
      });
      for (final r in rows(rule['revisions'])) {
        _put('recurring_rule_revisions', {
          'id': r['id'],
          'rule_id': rule['id'],
          'effective_from': r['effective'],
          'body': jsonEncode(r),
        });
      }
    }
    for (final e in all('entry', deleted: true)) {
      if (e['rule'] != null) {
        _put('recurring_occurrences', {
          'id': e['id'],
          'rule_id': e['rule'],
          'scheduled_on': e['scheduled_on'] ?? e['date'],
          'rule_revision_id': e['rule_revision'],
          'transaction_id': e['deleted'] == true ? null : e['id'],
          'status': e['deleted'] == true ? 'skipped' : 'generated',
        });
      }
      if (e['deleted'] == true) continue;
      if (!rows(
        e['postings'],
      ).every((p) => accountIds.contains(p['account']))) {
        pending.add('entry/${e['id']}: 연결 계좌 수신 대기');
        continue;
      }
      if ([
        ...rows(e['receipts']),
        ...rows(e['refunds']),
      ].any((r) => r['voided'] != true && !accountIds.contains(r['account']))) {
        pending.add('entry/${e['id']}: 정산·환불 계좌 수신 대기');
        continue;
      }
      if (e['rule'] != null) {
        final rule = get('rule', e['rule'] as String);
        if (rule == null ||
            !rows(
              rule['revisions'],
            ).any((r) => r['id'] == e['rule_revision'])) {
          pending.add('entry/${e['id']}: 정기 규칙 확인 필요');
          continue;
        }
      }
      _transactionRows(e);
      final shares = rows(e['shares']);
      if (shares.isNotEmpty) {
        _put('settlements', {'id': e['id'], 'expense_transaction_id': e['id']});
      }
      for (final share in shares) {
        _person(share['person'] as String);
        _put('settlement_shares', {
          'id': share['id'],
          'settlement_id': e['id'],
          'person_id': _personId(share['person'] as String),
          'claimed_amount': share['amount'],
        });
      }
      for (final r in rows(e['receipts']).where((r) => r['voided'] != true)) {
        if (!accountIds.contains(r['account'])) {
          pending.add('정산 ${r['id']}: 연결 계좌 수신 대기');
          continue;
        }
        _transactionRows({
          'id': r['id'],
          'date': r['date'],
          'type': 'receipt',
          'amount': r['amount'],
          'memo': r['memo'] ?? '정산금 받음',
          'postings': [
            {'account': r['account'], 'delta': r['amount']},
          ],
          'owner': e['id'],
        });
        _put('settlement_receipts', {
          'id': r['id'],
          'share_id': r['share'],
          'transaction_id': r['id'],
          'amount': r['amount'],
        });
      }
      for (final r in rows(e['refunds']).where((r) => r['voided'] != true)) {
        final allocations = rows(r['allocations']);
        _transactionRows({
          'id': r['id'],
          'date': r['date'],
          'type': 'refund',
          'amount': r['amount'],
          'memo': '환불 · ${e['memo']}',
          'postings': [
            {'account': r['account'], 'delta': r['amount']},
          ],
          'allocations': allocations,
          'owner': e['id'],
        });
      }
    }
    for (final d in all('debt')) {
      if (rows(d['events']).any(
        (e) =>
            e['voided'] != true &&
            e['account'] != null &&
            !accountIds.contains(e['account']),
      )) {
        pending.add('debt/${d['id']}: 연결 계좌 수신 대기');
        continue;
      }
      _person(d['person'] as String);
      _put('debts', {
        'id': d['id'],
        'person_id': _personId(d['person'] as String),
        'direction': d['direction'],
        'opened_on': d['date'],
        'due_on': d['due'],
        'memo': d['memo'],
      });
      for (final e in rows(d['events']).where((e) => e['voided'] != true)) {
        final repay = e['type'] == 'repay';
        final sign = (d['direction'] == 'lent' ? -1 : 1) * (repay ? -1 : 1);
        _put('debt_events', {
          'id': e['id'],
          'debt_id': d['id'],
          'type': e['type'],
          'principal_amount': e['amount'],
          'date': e['date'],
          'transaction_id': e['account'] == null ? null : e['id'],
        });
        if (e['account'] != null) {
          if (!accountIds.contains(e['account'])) {
            pending.add('빚 ${e['id']}: 연결 계좌 수신 대기');
            continue;
          }
          _transactionRows({
            'id': e['id'],
            'date': e['date'],
            'type': 'debt',
            'amount': e['amount'],
            'memo': '${d['person']} · ${repay ? '원금 상환' : '원금 등록'}',
            'postings': [
              {'account': e['account'], 'delta': sign * (e['amount'] as int)},
            ],
            'owner': d['id'],
          });
        }
      }
    }
  }

  String _personId(String name) => stableId('$ledgerId/person/$name');
  void _person(String name) =>
      _put('people', {'id': _personId(name), 'name': name});
  void _transactionRows(Json e) {
    _put('transactions', {
      'id': e['id'],
      'date': e['date'],
      'type': e['type'],
      'amount': e['amount'],
      'memo': e['memo'] ?? '',
      'owner_id': e['owner'] ?? e['id'],
    });
    var i = 0;
    for (final p in rows(e['postings'])) {
      _put('postings', {
        'id': '${e['id']}:${i++}',
        'transaction_id': e['id'],
        'account_id': p['account'],
        'delta': p['delta'],
      });
    }
    i = 0;
    for (final a in rows(e['allocations'])) {
      _put('transaction_allocations', {
        'id': '${e['id']}:${i++}',
        'transaction_id': e['id'],
        'amount': a['amount'],
        'category_name': a['category_name'],
        'subcategory_name': a['subcategory_name'],
        'category_id': a['category_id'],
        'subcategory_id': a['subcategory_id'],
      });
    }
  }

  int balance(String account) =>
      query(
            'SELECT COALESCE(SUM(delta),0) n FROM postings WHERE account_id=?',
            [account],
          ).first['n']
          as int;
  int flow(String period, String type) =>
      query(
            'SELECT COALESCE(SUM(a.amount),0) n FROM transaction_allocations a JOIN transactions t ON t.id=a.transaction_id WHERE t.date LIKE ? AND ${type == 'income' ? "t.type='income'" : "t.type IN ('expense','refund')"}',
            ['$period%'],
          ).first['n']
          as int;
  List<Json> entries({
    String period = '',
    String? account,
    String search = '',
  }) {
    return query(
          'SELECT DISTINCT t.* FROM transactions t JOIN postings p ON t.id=p.transaction_id WHERE t.date LIKE ? ${account == null ? '' : 'AND p.account_id=?'} ORDER BY t.date DESC,t.id',
          ['$period%', ?account],
        )
        .where(
          (e) =>
              search.isEmpty ||
              '${e['memo']} ${allocations(e['id'] as String)}'.contains(search),
        )
        .toList();
  }

  List<Json> allocations(String transaction) => query(
    'SELECT * FROM transaction_allocations WHERE transaction_id=?',
    [transaction],
  );
  Json exportBackup() => {
    'format': 'chagok-backup',
    'version': 1,
    'ledger': ledgerId,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'changes': events,
  };
  void restoreBackup(Json backup, {bool asNew = true}) {
    require(
      backup['format'] == 'chagok-backup' && backup['version'] == 1,
      '지원하지 않는 백업 파일입니다.',
    );
    final source = LedgerStore.memory(ledger: backup['ledger'] as String);
    try {
      source.merge(rows(backup['changes']));
      require(
        source.pending.isEmpty && source.conflicts.isEmpty,
        '미해결 충돌 또는 누락된 기록이 있는 백업입니다.',
      );
      final oldId = ledgerId;
      try {
        _transaction(() {
          db.execute('DELETE FROM change_events; DELETE FROM sync_deliveries');
          ledgerId = asNew ? uuid.v4() : backup['ledger'] as String;
          setLocal('ledger_id', ledgerId);
          if (asNew) {
            for (final item in source._documents.entries) {
              _insert(
                _event(item.key.split('/').first, item.value, []),
                uploaded: false,
              );
            }
          } else {
            for (final event in source.events) {
              _insert(event, uploaded: true);
            }
          }
          _rebuild();
        });
      } catch (_) {
        ledgerId = oldId;
        _rebuild();
        rethrow;
      }
    } finally {
      source.close();
    }
  }

  Json checkpoint() => {
    'format': 'chagok-device',
    'version': 1,
    'ledger': ledgerId,
    'changes': events,
    'local': {
      for (final row in query('SELECT * FROM local_settings'))
        row['key'] as String: row['value'],
    },
    'uploaded': query(
      'SELECT id FROM sync_deliveries WHERE uploaded=1',
    ).map((r) => r['id']).toList(),
  };

  /// Only called on a fresh store. Preserve conflicts and missing parents too.
  void loadCheckpoint(Json snapshot) {
    require(
      snapshot['format'] == 'chagok-device' && snapshot['version'] == 1,
      '지원하지 않는 기기 저장 형식입니다.',
    );
    require(events.isEmpty, '이미 열린 가계부에 기기 파일을 덮어쓸 수 없어요.');
    final settings = Map<String, dynamic>.from(snapshot['local'] as Map);
    require(
      settings['ledger_id'] == snapshot['ledger'] &&
          settings['device_id'] is String &&
          settings.values.every((v) => v is String),
      '기기 설정이 손상되었어요.',
    );
    ledgerId = snapshot['ledger'] as String;
    merge(rows(snapshot['changes']));
    db.execute(
      'DELETE FROM local_settings; UPDATE sync_deliveries SET uploaded=0',
    );
    for (final e in settings.entries) {
      setLocal(e.key, e.value as String);
    }
    deviceId = settings['device_id'] as String;
    for (final id in snapshot['uploaded'] as List) {
      uploaded(id as String);
    }
  }

  void close() {
    if (!_closed) {
      _closed = true;
      db.close();
    }
  }
}

const schema = <String, String>{
  'accounts':
      'id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,is_liquid INTEGER NOT NULL,is_archived INTEGER NOT NULL',
  'categories':
      'id TEXT PRIMARY KEY,type TEXT NOT NULL,parent_id TEXT,name TEXT NOT NULL,deleted INTEGER NOT NULL',
  'transactions':
      'id TEXT PRIMARY KEY,date TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL,memo TEXT NOT NULL,owner_id TEXT NOT NULL',
  'postings':
      'id TEXT PRIMARY KEY,transaction_id TEXT NOT NULL,account_id TEXT NOT NULL,delta INTEGER NOT NULL',
  'transaction_allocations':
      'id TEXT PRIMARY KEY,transaction_id TEXT NOT NULL,amount INTEGER NOT NULL,category_name TEXT NOT NULL,subcategory_name TEXT,category_id TEXT,subcategory_id TEXT',
  'people': 'id TEXT PRIMARY KEY,name TEXT NOT NULL',
  'settlements': 'id TEXT PRIMARY KEY,expense_transaction_id TEXT NOT NULL',
  'settlement_shares':
      'id TEXT PRIMARY KEY,settlement_id TEXT NOT NULL,person_id TEXT NOT NULL,claimed_amount INTEGER NOT NULL',
  'settlement_receipts':
      'id TEXT PRIMARY KEY,share_id TEXT NOT NULL,transaction_id TEXT NOT NULL,amount INTEGER NOT NULL',
  'debts':
      'id TEXT PRIMARY KEY,person_id TEXT NOT NULL,direction TEXT NOT NULL,opened_on TEXT NOT NULL,due_on TEXT,memo TEXT NOT NULL',
  'debt_events':
      'id TEXT PRIMARY KEY,debt_id TEXT NOT NULL,type TEXT NOT NULL,principal_amount INTEGER NOT NULL,date TEXT NOT NULL,transaction_id TEXT',
  'recurring_rules':
      'id TEXT PRIMARY KEY,status TEXT NOT NULL,body TEXT NOT NULL',
  'recurring_rule_revisions':
      'id TEXT PRIMARY KEY,rule_id TEXT NOT NULL,effective_from TEXT NOT NULL,body TEXT NOT NULL',
  'recurring_occurrences':
      'id TEXT PRIMARY KEY,rule_id TEXT NOT NULL,scheduled_on TEXT NOT NULL,rule_revision_id TEXT NOT NULL,transaction_id TEXT,status TEXT NOT NULL,UNIQUE(rule_id,scheduled_on)',
  'budgets':
      'id TEXT PRIMARY KEY,month TEXT NOT NULL,category_id TEXT,amount INTEGER NOT NULL',
};
