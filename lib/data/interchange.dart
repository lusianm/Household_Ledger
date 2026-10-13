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
  ImportRow(
    this.number, {
    this.entry,
    this.error,
    this.action = '추가',
    this.baseDigest,
    this.duplicate = false,
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
          sumMoney(
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
      ['차곡 가계부 · 내역 시트만 가져오기 대상으로 사용합니다.'],
      ['새 기록은 거래ID·기준버전을 비워 주세요. 기존 기록은 두 열을 유지해 주세요.'],
      ['정산·환불·분할 지출은 연결 관계 보존을 위해 앱에서 수정합니다. 전체 기록 시트에서 조회할 수 있습니다.'],
      ['행 삭제는 앱 기록을 삭제하지 않습니다. 전체 복구에는 JSON 백업을 사용해 주세요.'],
    ]);
    return Uint8List.fromList(book.encode()!);
  }

  List<ImportRow> preview(Uint8List bytes, String extension) {
    require(bytes.length <= 20 * 1024 * 1024, '20MB 이하의 파일을 선택해 주세요.');
    List<List<dynamic>> data;
    if (extension.toLowerCase() == 'xlsx') {
      final book = Excel.decodeBytes(bytes);
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
        final id = cell('거래ID').trim();
        final existing = id.isEmpty ? null : service.store.get('entry', id);
        require(
          id.isEmpty || existing != null,
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
          existing == null || digest(existing) == base,
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
          id: existing?['id'] as String?,
          type: type!,
          amount: amount,
          account: matchAccount(cell('계좌')),
          destination: type == 'transfer' ? matchAccount(cell('도착계좌')) : null,
          on: cell('날짜').trim(),
          memo: cell('메모'),
          allocations: type == 'transfer'
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
          for (final key in ['rule', 'rule_revision', 'scheduled_on']) {
            if (existing.containsKey(key)) entry[key] = existing[key];
          }
        }
        validateDocument('entry', entry);
        final signature = digest({...entry, 'id': ''});
        final duplicate =
            !seen.add(id.isEmpty ? signature : id) ||
            existing == null &&
                service.store
                    .all('entry')
                    .any((e) => digest({...e, 'id': ''}) == signature);
        result.add(
          ImportRow(
            i + 1,
            entry: entry,
            action: existing == null
                ? '추가'
                : digest(existing) == digest(entry)
                ? '변경 없음'
                : '수정',
            baseDigest: existing == null ? null : base,
            duplicate: duplicate,
          ),
        );
      } catch (e) {
        result.add(ImportRow(i + 1, error: e.toString()));
      }
    }
    return result;
  }

  void apply(List<ImportRow> selected) {
    final changes = <(String, Json)>[];
    for (final row in selected) {
      require(row.error == null && row.entry != null, '오류 행을 제외해 주세요.');
      if (row.action == '변경 없음') continue;
      if (row.baseDigest != null) {
        require(
          digest(service.store.get('entry', row.entry!['id'] as String)) ==
              row.baseDigest,
          '검토 도중 변경된 내역이 있어요. 다시 불러와 주세요.',
        );
      }
      changes.add(('entry', row.entry!));
    }
    service.store.saveBatch(changes);
  }
}
