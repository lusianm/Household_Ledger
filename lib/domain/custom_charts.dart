import '../data/ledger_store.dart';
import 'value.dart';

void validateCustomChart(Json chart) {
  require(
    chart['name'] is String &&
        (chart['name'] as String).trim().isNotEmpty &&
        (chart['name'] as String).length <= 80,
    '그래프 이름은 1~80자로 입력해 주세요.',
  );
  require(chart['other'] is bool, '그 외 분류 표시를 확인해 주세요.');
  final groups = rows(chart['groups']);
  require(groups.isNotEmpty && groups.length <= 20, '묶음은 1~20개까지 만들 수 있어요.');
  final names = <String>{};
  final selected = <Json>[];
  for (final group in groups) {
    final name = group['name'];
    require(
      name is String &&
          name.trim().isNotEmpty &&
          name.length <= 80 &&
          name != '그 외' &&
          names.add(name),
      '묶음 이름을 서로 다르게 입력해 주세요. ‘그 외’는 사용할 수 없어요.',
    );
    final selectors = rows(group['selectors']);
    require(selectors.isNotEmpty, '각 묶음에 분류를 하나 이상 선택해 주세요.');
    for (final selector in selectors) {
      require(
        selector['category'] is String &&
            (selector['category'] as String).isNotEmpty &&
            (selector['sub'] == null || selector['sub'] is String),
        '선택한 분류를 확인해 주세요.',
      );
      require(
        !selected.any(
          (old) =>
              old['category'] == selector['category'] &&
              (old['sub'] == null ||
                  selector['sub'] == null ||
                  old['sub'] == selector['sub']),
        ),
        '같은 분류를 중복 선택했어요. 대분류 전체와 그 소분류를 함께 선택할 수 없습니다.',
      );
      selected.add(selector);
    }
  }
}

List<(String, int)> customChartTotals(
  LedgerStore store,
  String period,
  Json chart,
) {
  validateCustomChart(chart);
  final groups = rows(chart['groups']);
  final totals = <String, int>{for (final g in groups) g['name'] as String: 0};
  var other = 0;
  final allocations = store.query(
    '''
    SELECT a.category_name, COALESCE(a.subcategory_name,'') sub, SUM(a.amount) amount
    FROM transaction_allocations a JOIN transactions t ON t.id=a.transaction_id
    WHERE t.id NOT IN (SELECT transaction_id FROM settlement_members)
      AND t.date LIKE ? AND t.type IN ('expense','refund')
    GROUP BY a.category_name, COALESCE(a.subcategory_name,'')
  ''',
    ['$period%'],
  );
  for (final allocation in allocations) {
    final match = groups
        .where(
          (group) => rows(group['selectors']).any(
            (s) =>
                s['category'] == allocation['category_name'] &&
                (s['sub'] == null || s['sub'] == allocation['sub']),
          ),
        )
        .firstOrNull;
    final amount = allocation['amount'] as int;
    if (match == null) {
      other += amount;
    } else {
      final name = match['name'] as String;
      totals[name] = totals[name]! + amount;
    }
  }
  return [
    for (final e in totals.entries) (e.key, e.value),
    if (chart['other'] == true) ('그 외', other),
  ];
}
