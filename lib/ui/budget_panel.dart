import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../domain/budget.dart';
import '../domain/value.dart';
import 'common.dart';
import 'custom_charts.dart';
import 'money_input.dart';

class BudgetPanel extends StatelessWidget {
  final AppController app;
  final String month;
  const BudgetPanel({super.key, required this.app, required this.month});
  @override
  Widget build(BuildContext context) {
    final budget = app.store
        .all('budget')
        .where((b) => b['month'] == month && b['category'] == null)
        .firstOrNull;
    final used = budget == null ? 0 : budgetUsed(app.store, budget);
    final limit = budget?['amount'] as int? ?? 0;
    final exceeded = used > limit;
    final color = exceeded ? const Color(0xffcf3030) : const Color(0xff1769cc);
    final mode = budget?['filter_mode'] ?? 'all';
    final description = mode == 'all'
        ? '전체 지출'
        : '${rows(budget?['selectors']).map((s) => '${s['category']} › ${s['sub'] ?? '전체'}').join(', ')} ${mode == 'include' ? '만 포함' : '제외'}';
    return panel(
      '$month 월간 예산',
      budget == null
          ? const Text('예산 금액과 포함·제외할 카테고리를 설정하면 사용액을 자동으로 계산합니다.')
          : spaced([
              Text(description),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '사용 ${money(used)}',
                    key: const ValueKey('budget-used'),
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  Text('예산 ${money(limit)}'),
                ],
              ),
              LinearProgressIndicator(
                value: limit == 0
                    ? (used > 0 ? 1 : 0)
                    : (used / limit).clamp(0, 1),
                color: color,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                minHeight: 8,
              ),
              Text(
                exceeded
                    ? '${money(used - limit)} 초과 사용'
                    : '${money(limit - used)} 남음',
                style: TextStyle(fontWeight: FontWeight.bold, color: color),
              ),
              const Text(
                '선택한 달의 실제 지출에서 환불을 차감합니다. 정기 예상 금액은 포함하지 않습니다.',
                style: TextStyle(fontSize: 12),
              ),
            ]),
      trailing: TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => _BudgetEditor(app: app, month: month, budget: budget),
        ),
        child: Text(budget == null ? '예산 설정' : '예산 수정'),
      ),
    );
  }
}

class _BudgetEditor extends StatefulWidget {
  final AppController app;
  final String month;
  final Json? budget;
  const _BudgetEditor({required this.app, required this.month, this.budget});
  @override
  State<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<_BudgetEditor> {
  late final TextEditingController amount;
  late String mode;
  late List<Json> selectors;
  String? error;
  @override
  void initState() {
    super.initState();
    amount = TextEditingController(
      text: const MoneyInputFormatter().format(
        '${widget.budget?['amount'] ?? 0}',
      ),
    );
    mode = widget.budget?['filter_mode'] as String? ?? 'all';
    selectors = rows(widget.budget?['selectors']);
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.month} 월간 예산 설정'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: spaced([
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            inputFormatters: const [MoneyInputFormatter()],
            decoration: const InputDecoration(
              labelText: '예산 금액',
              suffixText: '원',
            ),
          ),
          selectField<String>('집계 대상', mode, const [
            ('all', '전체 지출'),
            ('include', '선택한 카테고리만 포함'),
            ('exclude', '선택한 카테고리는 제외'),
          ], (v) => setState(() => mode = v!)),
          if (mode != 'all') ...[
            Text(
              selectors.isEmpty
                  ? '대분류 또는 소분류를 선택해 주세요.'
                  : selectors
                        .map((s) => '${s['category']} › ${s['sub'] ?? '전체'}')
                        .join(', '),
            ),
            OutlinedButton(
              onPressed: () async {
                final selected = await chooseBudgetCategories(
                  context,
                  widget.app,
                  selectors,
                );
                if (selected != null && mounted) {
                  setState(() => selectors = selected);
                }
              },
              child: const Text('카테고리 선택'),
            ),
          ],
          const Text('이 설정은 선택한 월에만 적용됩니다. 실제 거래 분류는 변경하지 않습니다.'),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ]),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final id =
                widget.budget?['id'] as String? ??
                stableId('${widget.app.store.ledgerId}/budget/${widget.month}');
            final current = widget.app.store.get('budget', id);
            require(
              widget.budget == null
                  ? current == null || current['deleted'] == true
                  : current != null && digest(current) == digest(widget.budget),
              '예산이 변경됐어요. 다시 열어 주세요.',
            );
            widget.app.store.save('budget', {
              'id': id,
              'month': widget.month,
              'amount': parseMoney(amount.text),
              'category': null,
              'filter_mode': mode,
              'selectors': mode == 'all' ? <Json>[] : selectors,
            });
            widget.app.changed();
            Navigator.pop(context);
          } catch (e) {
            setState(() => error = '$e');
          }
        },
        child: const Text('예산 저장'),
      ),
    ],
  );
}
