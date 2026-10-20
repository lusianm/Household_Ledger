import '../data/ledger_store.dart';
import 'custom_charts.dart';
import 'value.dart';

void validateBudgetFilter(Json budget) {
  final mode = budget['filter_mode'] ?? 'all';
  require(['all', 'include', 'exclude'].contains(mode), '예산 집계 방식을 확인해 주세요.');
  if (mode != 'all') {
    validateCustomChart({
      'name': '예산',
      'other': false,
      'groups': [
        {'name': '대상', 'selectors': budget['selectors']},
      ],
    });
  }
}

int budgetUsed(LedgerStore store, Json budget) {
  final mode = budget['filter_mode'] ?? 'all';
  final month = budget['month'] as String;
  if (mode == 'all') return store.flow(month, 'expense');
  validateBudgetFilter(budget);
  final totals = customChartTotals(store, month, {
    'name': '예산',
    'other': true,
    'groups': [
      {'name': '대상', 'selectors': budget['selectors']},
    ],
  });
  return mode == 'include' ? totals.first.$2 : totals.last.$2;
}
