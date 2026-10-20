import 'dart:convert';
import '../domain/ledger_service.dart';
import '../domain/validation.dart';
import '../domain/value.dart';

/// Only the app writes checkpoints. External clients exchange versioned requests
/// and durable receipts through the selected local folder.
class FileConnection {
  final LedgerService service;
  final Future<void> Function() flush;
  final Future<String> Function() backup;
  final Future<String?> Function() readRequest;
  final Future<void> Function(String, Json) write;
  final bool Function() paused;
  bool busy = false;
  String? error;

  FileConnection({
    required this.service,
    required this.flush,
    required this.backup,
    required this.readRequest,
    required this.write,
    required this.paused,
  });

  static const sessionKey = 'file_connection_session';
  static const receiptKey = 'file_connection_receipt';
  String? get session => service.store.local(sessionKey);
  bool get enabled => session != null;

  bool editable(Json e) =>
      ['income', 'expense', 'transfer'].contains(e['type']) &&
      e['deleted'] != true &&
      rows(e['shares']).isEmpty &&
      rows(e['receipts']).isEmpty &&
      rows(e['refunds']).isEmpty &&
      rows(e['allocations']).length <= 1 &&
      !service.store.conflicts.containsKey('entry/${e['id']}') &&
      !service.store
          .all('settlement_group')
          .any(
            (g) =>
                g['closed'] == true && (g['members'] as List).contains(e['id']),
          );

  Json snapshot() => {
    'format': 'chagok-file-snapshot',
    'version': 1,
    'ledger': service.store.ledgerId,
    'connection': session,
    'enabled': enabled,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
    'accounts': [
      for (final a in service.store.all('account'))
        {...a, 'balance': service.store.balance(a['id'] as String)},
    ],
    'categories': service.store.all('category'),
    'entries': [
      for (final e in service.store.all('entry'))
        {'data': e, 'base': digest(e), 'editable': editable(e)},
    ],
    'settlements': service.store.all('settlement_group'),
    'unsent': service.store.unsent,
  };

  List<(String, Json)> prepare(Json request) {
    require(
      request['format'] == 'chagok-file-request' && request['version'] == 1,
      '지원하지 않는 파일 수정 요청입니다.',
    );
    require(
      enabled &&
          request['connection'] == session &&
          request['ledger'] == service.store.ledgerId,
      '가계부 또는 연결이 달라요. 최신 snapshot.json을 읽어 주세요.',
    );
    require(
      request['id'] is String &&
          RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(request['id'] as String),
      '요청 ID를 확인해 주세요.',
    );
    final operations = request['operations'];
    require(
      operations is List && operations.isNotEmpty && operations.length <= 500,
      '한 번에 1~500건을 수정할 수 있어요.',
    );
    final changes = <(String, Json)>[];
    final ids = <String>{};
    for (final item in operations as List) {
      require(item is Map<String, dynamic>, '수정 항목 형식을 확인해 주세요.');
      final op = item as Json;
      require(
        op['id'] is String && ids.add(op['id'] as String),
        '중복되거나 없는 거래 ID입니다.',
      );
      final old = service.store.get('entry', op['id'] as String);
      require(
        old != null && editable(old),
        '수정할 수 없는 거래입니다. 정산·환불·분할·충돌 상태를 확인해 주세요.',
      );
      require(op['base'] == digest(old), '검토 후 거래가 변경됐어요. 최신 내역으로 다시 요청해 주세요.');
      require(op['set'] is Map<String, dynamic>, '변경할 필드가 필요해요.');
      final patch = op['set'] as Json;
      const fields = {
        'date',
        'memo',
        'amount',
        'type',
        'account',
        'destination',
        'category',
        'subcategory',
      };
      require(
        patch.isNotEmpty && patch.keys.every(fields.contains),
        '지원하지 않는 변경 필드입니다.',
      );
      for (final field in patch.keys.where((k) => k != 'amount')) {
        require(patch[field] is String, '$field 값은 문자열이어야 해요.');
      }
      final type = patch['type'] as String? ?? old!['type'] as String;
      require(
        ['income', 'expense', 'transfer'].contains(type),
        '거래 유형을 확인해 주세요.',
      );
      final amount = patch['amount'] ?? old!['amount'];
      positiveMoney(amount);
      final posts = rows(old!['postings']);
      final account =
          patch['account'] as String? ?? posts.first['account'] as String;
      final destination =
          patch['destination'] as String? ??
          (posts.length == 2 ? posts.last['account'] as String : null);
      for (final id in [account, if (type == 'transfer') destination]) {
        final a = id == null ? null : service.store.get('account', id);
        require(
          a != null && a['deleted'] != true && a['archived'] != true,
          '사용할 수 있는 계좌 ID를 지정해 주세요.',
        );
      }
      require(
        type == 'transfer' || !patch.containsKey('destination'),
        '도착 계좌는 이동에만 지정할 수 있어요.',
      );
      final oldAllocation = rows(old['allocations']).firstOrNull;
      final typeChanged = type != old['type'];
      final category =
          patch['category'] as String? ??
          (typeChanged ? '' : oldAllocation?['category_name'] as String? ?? '');
      final subcategory =
          patch['subcategory'] as String? ??
          (typeChanged || patch.containsKey('category')
              ? ''
              : oldAllocation?['subcategory_name'] as String? ?? '');
      require(
        category.isNotEmpty || (type == 'transfer' && subcategory.isEmpty),
        '수입·지출 대분류를 지정해 주세요.',
      );
      final parents = service.store
          .all('category')
          .where(
            (c) =>
                c['type'] == type &&
                c['parent'] == null &&
                c['name'] == category,
          )
          .toList();
      final parent = parents.length == 1 ? parents.single : null;
      final children = service.store
          .all('category')
          .where(
            (c) =>
                parent != null &&
                c['parent'] == parent['id'] &&
                c['name'] == subcategory,
          )
          .toList();
      final updated = {
        ...old,
        ...service.makeEntry(
          id: old['id'] as String,
          type: type,
          amount: amount as int,
          account: account,
          destination: type == 'transfer' ? destination : null,
          on: patch['date'] as String? ?? old['date'] as String,
          memo: patch['memo'] as String? ?? old['memo'] as String,
          allocations: category.isEmpty
              ? []
              : [
                  service.allocation(
                    amount,
                    category,
                    subcategory: subcategory,
                    categoryId: parent?['id'] as String?,
                    subcategoryId: children.length == 1
                        ? children.single['id'] as String
                        : null,
                  ),
                ],
        ),
      };
      validateDocument('entry', updated);
      changes.add(('entry', updated));
    }
    return changes;
  }

  Future<void> poll() async {
    if (busy || !enabled || paused()) return;
    busy = true;
    error = null;
    try {
      await flush();
      final text = await readRequest();
      Json? receipt;
      if (text != null && text.trim().isNotEmpty) {
        require(
          utf8.encode(text).length <= 1024 * 1024,
          '수정 요청은 1MiB 이하여야 해요.',
        );
        final request = jsonDecode(text) as Json;
        final hash = digest(request);
        final previousText = service.store.local(receiptKey);
        final previous = previousText == null
            ? null
            : jsonDecode(previousText) as Json;
        // Do not replay a committed batch when a result-file write was interrupted.
        if (previous?['id'] == request['id'] &&
            previous?['request_hash'] == hash) {
          receipt = previous;
        } else {
          try {
            require(previous?['id'] != request['id'], '이미 사용한 요청 ID입니다.');
            prepare(request);
            final backupPath = await backup();
            if (!enabled || paused()) return;
            // Revalidate after disk awaits, including edits made in the UI.
            final changes = prepare(request);
            receipt = {
              'format': 'chagok-file-result',
              'version': 1,
              'id': request['id'],
              'ledger': service.store.ledgerId,
              'connection': session,
              'request_hash': hash,
              'status': 'applied',
              'count': changes.length,
              'backup': backupPath,
              'applied_at': DateTime.now().toUtc().toIso8601String(),
              'entries': [
                for (final (_, e) in changes)
                  {'id': e['id'], 'base': digest(e)},
              ],
            };
            service.store.saveBatch(
              changes,
              localUpdates: {receiptKey: jsonEncode(receipt)},
            );
          } on LedgerException catch (e) {
            error = '$e';
            receipt = {
              'format': 'chagok-file-result',
              'version': 1,
              'id': request['id'],
              'ledger': request['ledger'],
              'connection': request['connection'],
              'request_hash': hash,
              'status': 'rejected',
              'error': '$e',
            };
          }
        }
      }
      // A success receipt is published only after checkpoint read-back succeeds.
      await flush();
      if (!enabled || paused()) return;
      await write('snapshot.json', snapshot());
      if (receipt != null) await write('result.json', receipt);
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
    }
  }
}
