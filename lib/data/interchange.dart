import 'dart:convert';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import '../domain/ledger_service.dart';
import '../domain/validation.dart';
import '../domain/value.dart';

class ImportRow {
  final int number;
  final Json? entry;
  final String? error;
  final String action;
  final String? baseDigest;
  final bool duplicate;
  final String kind;
  final Map<String, String> dependencies = {};
  ImportRow(
    this.number, {
    this.entry,
    this.error,
    this.action = '추가',
    this.baseDigest,
    this.duplicate = false,
    this.kind = 'entry',
  });
}

class Interchange {
  final LedgerService service;
  Interchange(this.service);
  static const headers = [
    '거래ID',
    '기준버전',
    '날짜',
    '유형',
    '금액',
    '계좌',
    '도착계좌',
    '대분류',
    '소분류',
    '메모',
    '가져오기키',
  ];
  String _account(String id) =>
      service.store.get('account', id)?['name'] as String? ?? id;
  List<List<dynamic>> exportRows() {
    final result = <List<dynamic>>[
      [...headers],
    ];
    for (final e in service.store.all('entry')) {
      // Linked settlements and refunds are exported on dedicated review sheets.
      if (rows(e['shares']).isNotEmpty ||
          rows(e['receipts']).isNotEmpty ||
          rows(e['refunds']).isNotEmpty ||
          rows(e['allocations']).length > 1 ||
          e['type'] == 'adjustment') {
        continue;
      }
      final posts = rows(e['postings']), allocations = rows(e['allocations']);
      final a = allocations.firstOrNull;
      result.add([
        e['id'],
        digest(e),
        e['date'],
        typeLabels[e['type']],
        e['amount'],
        _account(posts.first['account'] as String),
        posts.length > 1 ? _account(posts.last['account'] as String) : '',
        a?['category_name'] ?? '',
        a?['subcategory_name'] ?? '',
        e['memo'],
        e['import_key'] ?? '',
      ]);
    }
    return result;
  }

  Uint8List csvBytes() {
    dynamic safe(dynamic value) =>
        value is String && RegExp(r'^[=+\-@\t\r]').hasMatch(value)
        ? "'$value"
        : value;
    return Uint8List.fromList(
      utf8.encode(
        '\uFEFF${const ListToCsvConverter().convert(exportRows().map((r) => r.map(safe).toList()).toList())}',
      ),
    );
  }

  Uint8List excelBytes() {
    final book = Excel.createExcel();
    final groupedIds = service.store
        .query('SELECT transaction_id FROM settlement_members')
        .map((r) => r['transaction_id'])
        .toSet();
    book.rename('Sheet1', '내역');
    void write(String name, List<List<dynamic>> data) {
      final sheet = book[name];
      for (final row in data) {
        sheet.appendRow(
          row
              .map<CellValue?>(
                (v) => v is int ? IntCellValue(v) : TextCellValue('$v'),
              )
              .toList(),
        );
      }
      for (var i = 0; i < (data.firstOrNull?.length ?? 0); i++) {
        sheet.setColumnWidth(i, i < 2 ? 20 : 18);
      }
    }

    write('내역', exportRows());
    write('정산 묶음', [
      ['정산키', '정산ID', '기준버전', '이름', '기준일', '대분류', '소분류', '메모'],
      for (final g in service.store.all('settlement_group'))
        [
          g['id'],
          g['id'],
          digest(g),
          g['name'],
          g['date'],
          g['category_name'],
          g['subcategory_name'] ?? '',
          g['memo'],
        ],
    ]);
    write('정산 연결', [
      ['정산키', '거래참조'],
      for (final g in service.store.all('settlement_group'))
        for (final id in g['members'] as List)
          if (service.store.get('entry', id as String)?['deleted'] != true)
            [g['id'], id],
    ]);
    write('받을 돈 확인용', [
      ['정산', '상대방', '금액', '메모', '상태'],
      for (final g in service.store.all('settlement_group'))
        for (final c in rows(g['claims']))
          [
            g['name'],
            c['person'],
            c['amount'],
            c['memo'],
            c['debt'] != null
                ? '빚으로 이동'
                : c['received'] == true
                ? '받음'
                : '미수령',
          ],
    ]);
    write('전체 기록', [
      ['날짜', '유형', '금액', '메모', '분류', '수입·지출 반영액'],
      ...service.store.entries().map(
        (e) => [
          e['date'],
          typeLabels[e['type']] ?? e['type'],
          e['amount'],
          e['memo'],
          service.store
              .allocations(e['id'] as String)
              .map(
                (a) => '${a['category_name']} / ${a['subcategory_name'] ?? ''}',
              )
              .join(', '),
          groupedIds.contains(e['id'])
              ? 0
              : sumMoney(
                  service.store
                      .allocations(e['id'] as String)
                      .map((a) => a['amount'] as int),
                ),
        ],
      ),
    ]);
    write('정산', [
      ['결제일', '메모', '상대방', '청구액', '받은 금액', '남은 금액'],
      for (final e in service.store.all('entry'))
        for (final s in rows(e['shares']))
          [
            e['date'],
            e['memo'],
            s['person'],
            s['amount'],
            (s['amount'] as int) - service.remainingShare(e, s),
            service.remainingShare(e, s),
          ],
    ]);
    write('빚', [
      ['상대방', '종류', '발생일', '상환기한', '남은 원금', '메모'],
      ...service.store
          .all('debt')
          .map(
            (d) => [
              d['person'],
              d['direction'] == 'lent' ? '빌려준 돈' : '빌린 돈',
              d['date'],
              d['due'] ?? '',
              service.debtBalance(d),
              d['memo'],
            ],
          ),
    ]);
    write('정기 내역', [
      ['유형', '금액', '주기', '시작일', '종료일', '메모', '상태'],
      for (final rule in service.store.all('rule'))
        for (final r in [rows(rule['revisions']).last])
          [
            typeLabels[r['type']],
            r['amount'],
            r['cycle'] == 'monthly' ? '매월' : '매년',
            r['start'],
            r['end'] ?? '',
            r['memo'],
            rule['paused'] == true ? '중지' : '활성',
          ],
    ]);
    write('안내', [
      ['내역, 정산 묶음, 정산 연결 시트를 함께 가져옵니다. 받을 돈 확인용 시트는 조회 전용입니다.'],
      ['신규 거래의 가져오기키와 정산 연결의 거래참조를 맞춰 주세요. 기존 거래는 거래ID를 참조합니다.'],
      ['정산 묶음에는 합계를 입력하지 않습니다. 기준일에 연결된 거래의 입출금 차액을 자동 집계합니다.'],
      ['새 기록은 거래ID·기준버전을 비워 주세요. 기존 기록은 두 열을 유지해 주세요.'],
      ['정산·환불·분할 지출은 연결 관계 보존을 위해 앱에서 수정합니다. 전체 기록 시트에서 조회할 수 있습니다.'],
      ['행 삭제는 앱 기록을 삭제하지 않습니다. 전체 복구에는 JSON 백업을 사용해 주세요.'],
    ]);
    return Uint8List.fromList(book.encode()!);
  }

  List<ImportRow> preview(Uint8List bytes, String extension) {
    require(bytes.length <= 20 * 1024 * 1024, '20MB 이하의 파일을 선택해 주세요.');
    List<List<dynamic>> data;
    Excel? workbook;
    if (extension.toLowerCase() == 'xlsx') {
      final book = Excel.decodeBytes(bytes);
      workbook = book;
      final sheet = book.tables['내역'] ?? book.tables.values.first;
      data = sheet.rows
          .map(
            (r) => r.map((c) {
              final v = c?.value;
              if (v is DateCellValue) return day(v.asDateTimeLocal());
              if (v is DateTimeCellValue) {
                return day(DateTime(v.year, v.month, v.day));
              }
              if (v is FormulaCellValue) return '#수식은 값으로 바꿔 주세요';
              if (v is DoubleCellValue && v.value == v.value.roundToDouble()) {
                return v.value.toInt().toString();
              }
              return v?.toString() ?? '';
            }).toList(),
          )
          .toList();
    } else {
      data = const CsvToListConverter(
        shouldParseNumbers: false,
      ).convert(utf8.decode(bytes).replaceFirst('\uFEFF', ''));
    }
    require(data.isNotEmpty, '파일에 내역이 없어요.');
    final columns = data.first.map((v) => v.toString().trim()).toList();
    require(
      ['날짜', '유형', '금액', '계좌'].every(columns.contains),
      '필수 열: 날짜 / 유형 / 금액 / 계좌. 내보내기 양식을 사용해 주세요.',
    );
    final result = <ImportRow>[];
    final seen = <String>{};
    for (var i = 1; i < data.length; i++) {
      final row = data[i];
      if (row.every((v) => v.toString().trim().isEmpty)) continue;
      String cell(String name) {
        final index = columns.indexOf(name);
        return index < 0 || index >= row.length ? '' : row[index].toString();
      }

      try {
        final type = {
          '수입': 'income',
          '입금': 'income',
          '지출': 'expense',
          '이동': 'transfer',
        }[cell('유형').trim()];
        require(type != null, '유형은 수입·지출·이동 중 하나여야 해요.');
        final explicitId = cell('거래ID').trim();
        final importKey = cell('가져오기키').trim();
        final id = explicitId.isNotEmpty
            ? explicitId
            : importKey.isEmpty
            ? ''
            : stableId('${service.store.ledgerId}/import/$importKey');
        final existing = id.isEmpty ? null : service.store.get('entry', id);
        require(
          explicitId.isEmpty || existing != null,
          '현재 가계부에 없는 거래ID입니다. 신규 내역이면 ID를 비워 주세요.',
        );
        require(
          existing == null || existing['deleted'] != true,
          '이미 삭제한 내역입니다.',
        );
        require(
          existing == null ||
              (rows(existing['shares']).isEmpty &&
                  rows(existing['receipts']).isEmpty &&
                  rows(existing['refunds']).isEmpty &&
                  rows(existing['allocations']).length <= 1),
          '연결된 정산·환불·분할 지출은 앱에서 수정해 주세요.',
        );
        final base = cell('기준버전');
        require(
          existing == null ||
              (explicitId.isEmpty && importKey.isNotEmpty) ||
              digest(existing) == base,
          '내보낸 뒤 앱에서 바뀐 내역입니다. 최신 파일로 다시 확인해 주세요.',
        );
        String matchAccount(String name) {
          final found = service.store
              .all('account')
              .where((a) => a['name'] == name.trim())
              .toList();
          require(found.length == 1, '계좌 “$name”을 먼저 등록하거나 중복 이름을 정리해 주세요.');
          return found.single['id'] as String;
        }

        final amount = parseMoney(cell('금액'));
        final cat = cell('대분류'), sub = cell('소분류');
        require(
          cat.trim().isNotEmpty || sub.trim().isEmpty,
          '소분류의 대분류를 입력해 주세요.',
        );
        final parents = service.store
            .all('category')
            .where(
              (c) =>
                  c['type'] == type &&
                  c['parent'] == null &&
                  (c['name'] as String).trim() == cat.trim(),
            )
            .toList();
        final parent = parents.length == 1 ? parents.single : null;
        final children = parent == null
            ? <Json>[]
            : service.store
                  .all('category')
                  .where(
                    (c) =>
                        c['parent'] == parent['id'] &&
                        (c['name'] as String).trim() == sub.trim(),
                  )
                  .toList();
        final oldAllocation = existing == null
            ? null
            : rows(existing['allocations']).firstOrNull;
        final sameCategory =
            existing?['type'] == type && oldAllocation?['category_name'] == cat;
        final entry = service.makeEntry(
          id: id.isEmpty ? null : id,
          type: type!,
          amount: amount,
          account: matchAccount(cell('계좌')),
          destination: type == 'transfer' ? matchAccount(cell('도착계좌')) : null,
          on: cell('날짜').trim(),
          memo: cell('메모'),
          allocations: type == 'transfer' && cat.trim().isEmpty
              ? []
              : [
                  service.allocation(
                    amount,
                    cat,
                    subcategory: sub.isEmpty ? null : sub,
                    categoryId:
                        (sameCategory
                                ? (oldAllocation?['category_id'])
                                : (parent?['id']))
                            as String?,
                    subcategoryId:
                        sameCategory &&
                            (oldAllocation?['subcategory_name'] ?? '') == sub
                        ? (oldAllocation?['subcategory_id'] as String?)
                        : children.length == 1
                        ? children.single['id'] as String
                        : null,
                  ),
                ],
        );
        if (existing != null) {
          for (final key in [
            'rule',
            'rule_revision',
            'scheduled_on',
            'import_key',
          ]) {
            if (existing.containsKey(key)) entry[key] = existing[key];
          }
        }
        if (importKey.isNotEmpty) entry['import_key'] = importKey;
        require(
          existing == null ||
              explicitId.isNotEmpty ||
              digest(existing) == digest(entry),
          '같은 가져오기키의 내역이 이미 변경되어 있어요. 최신 내보내기 파일을 사용해 주세요.',
        );
        validateDocument('entry', entry);
        Json comparable(Json e) => {...e, 'id': ''}..remove('import_key');
        final signature = digest(comparable(entry));
        final duplicate =
            !seen.add(id.isEmpty ? signature : id) ||
            existing == null &&
                service.store
                    .all('entry')
                    .any((e) => digest(comparable(e)) == signature);
        result.add(
          ImportRow(
            i + 1,
            entry: entry,
            action: existing == null
                ? '추가'
                : digest(existing) == digest(entry)
                ? '변경 없음'
                : '수정',
            baseDigest: existing == null ? null : digest(existing),
            duplicate: duplicate,
          ),
        );
      } catch (e) {
        result.add(ImportRow(i + 1, error: e.toString()));
      }
    }
    if (workbook != null) _previewGroups(workbook, result);
    return result;
  }

  void _previewGroups(Excel book, List<ImportRow> result) {
    List<Map<String, String>> sheet(String name) {
      final data = book.tables[name]?.rows;
      if (data == null || data.isEmpty) return [];
      String value(Data? c) {
        final v = c?.value;
        require(v is! FormulaCellValue, '$name 시트의 수식을 값으로 바꿔 주세요.');
        if (v is DateCellValue) return day(v.asDateTimeLocal());
        if (v is DateTimeCellValue) {
          return day(DateTime(v.year, v.month, v.day));
        }
        return v?.toString() ?? '';
      }

      final headers = data.first.map((c) => value(c).trim()).toList();
      return [
        for (final row in data.skip(1))
          if (row.any((c) => value(c).trim().isNotEmpty))
            {
              for (var i = 0; i < headers.length; i++)
                headers[i]: i < row.length ? value(row[i]) : '',
            },
      ];
    }

    final groups = sheet('정산 묶음'), links = sheet('정산 연결');
    if (groups.isEmpty && links.isEmpty) return;
    final aliases = <String, ImportRow>{};
    for (final r in result.where((r) => r.entry != null)) {
      for (final key in {
        r.entry!['id'],
        r.entry!['import_key'],
      }.whereType<String>().where((k) => k.isNotEmpty)) {
        require(!aliases.containsKey(key), '중복된 거래ID 또는 가져오기키입니다: $key');
        aliases[key] = r;
      }
    }
    final groupKeys = groups.map((g) => g['정산키']).toSet();
    require(
      groupKeys.length == groups.length &&
          !groupKeys.contains(null) &&
          !groupKeys.contains(''),
      '정산키는 비어 있거나 중복될 수 없어요.',
    );
    require(
      links.every((l) => groupKeys.contains(l['정산키'])),
      '정산 연결 시트에 정의되지 않은 정산키가 있어요.',
    );
    final used = <String>{};
    for (final (index, row) in groups.indexed) {
      require(
        !['금액', '수입', '지출', '합계', '순액'].any(row.containsKey),
        '정산 묶음에 금액 열을 넣지 마세요. 연결된 내역으로 자동 계산합니다.',
      );
      final key = row['정산키']!;
      final explicitId = row['정산ID'] ?? '';
      final id = explicitId.isEmpty
          ? stableId('${service.store.ledgerId}/settlement-import/$key')
          : explicitId;
      final old = service.store.get('settlement_group', id);
      require(
        explicitId.isEmpty || old != null,
        '현재 가계부에 없는 정산ID입니다. 신규 정산은 정산ID를 비워 주세요.',
      );
      require(
        old == null || old['deleted'] != true,
        '삭제한 정산의 키를 다시 사용할 수 없어요.',
      );
      require(
        old == null || explicitId.isEmpty || row['기준버전'] == digest(old),
        '정산이 변경됐어요. 최신 내보내기 파일을 사용해 주세요.',
      );
      final dependencies = <String, String>{};
      final memberRows = <ImportRow>[];
      final members = <String>[];
      for (final link in links.where((l) => l['정산키'] == key)) {
        final ref = link['거래참조'] ?? '';
        final imported = aliases[ref];
        final entry = imported?.entry ?? service.store.get('entry', ref);
        require(
          entry != null && entry['deleted'] != true,
          '정산 “$key”의 거래참조 “$ref”를 찾을 수 없어요. 내역의 오류도 확인해 주세요.',
        );
        final entryId = entry!['id'] as String;
        require(used.add(entryId), '하나의 거래는 한 정산에 한 번만 연결할 수 있어요: $ref');
        members.add(entryId);
        dependencies['entry/$entryId'] = digest(entry);
        if (imported != null) memberRows.add(imported);
      }
      members.sort();
      final group = <String, dynamic>{
        'id': id,
        'name': row['이름'] ?? '',
        'date': row['기준일'] ?? '',
        'category_name': row['대분류'] ?? '',
        'subcategory_name': (row['소분류'] ?? '').isEmpty ? null : row['소분류'],
        'memo': row['메모'] ?? '',
        'members': members,
        'claims': old?['claims'] ?? <Json>[],
        'closed': old?['closed'] ?? false,
        if (old?['category_id'] != null && old?['category_name'] == row['대분류'])
          'category_id': old!['category_id'],
        if (old?['subcategory_id'] != null &&
            old?['subcategory_name'] == row['소분류'])
          'subcategory_id': old!['subcategory_id'],
      };
      validateDocument('settlement_group', group);
      require(
        old == null || explicitId.isNotEmpty || digest(old) == digest(group),
        '이미 변경된 정산키입니다. 최신 내보내기 파일을 사용해 주세요.',
      );
      require(
        old == null || old['closed'] != true || digest(old) == digest(group),
        '마감된 정산입니다. 앱에서 다시 열어 주세요.',
      );
      final preview = ImportRow(
        index + 2,
        kind: 'settlement_group',
        entry: group,
        baseDigest: old == null ? null : digest(old),
        action: old == null
            ? '추가'
            : digest(old) == digest(group)
            ? '변경 없음'
            : '수정',
      );
      preview.dependencies.addAll(dependencies);
      for (final member in memberRows) {
        member.dependencies['settlement_group/$id'] = digest(group);
      }
      result.add(preview);
    }
  }

  void apply(List<ImportRow> selected) {
    final changes = <(String, Json)>[];
    final planned = <String, Json>{
      for (final r in selected.where((r) => r.entry != null))
        '${r.kind}/${r.entry!['id']}': r.entry!,
    };
    require(planned.length == selected.length, '같은 기록을 중복으로 선택했거나 오류 행이 있어요.');
    for (final row in selected) {
      require(row.error == null && row.entry != null, '오류 행을 제외해 주세요.');
      for (final dep in row.dependencies.entries) {
        final slash = dep.key.indexOf('/');
        final current =
            planned[dep.key] ??
            service.store.get(
              dep.key.substring(0, slash),
              dep.key.substring(slash + 1),
            );
        require(
          current != null && digest(current) == dep.value,
          '정산과 연결 거래를 함께 선택해 주세요. 변경된 내역이 있으면 파일을 다시 불러와 주세요.',
        );
      }
      if (row.baseDigest != null) {
        require(
          digest(service.store.get(row.kind, row.entry!['id'] as String)) ==
              row.baseDigest,
          '검토 도중 변경된 내역이 있어요. 다시 불러와 주세요.',
        );
      } else {
        require(
          service.store.get(row.kind, row.entry!['id'] as String) == null,
          '검토 도중 같은 기록이 추가됐어요. 파일을 다시 불러와 주세요.',
        );
      }
      if (row.action == '변경 없음') continue;
      changes.add((row.kind, row.entry!));
    }
    service.store.saveBatch(changes);
  }
}
