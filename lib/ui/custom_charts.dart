import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../domain/custom_charts.dart';
import '../domain/value.dart';
import 'common.dart';

class CustomCharts extends StatelessWidget {
  final AppController app;
  final String month;
  const CustomCharts({super.key, required this.app, required this.month});

  Future<void> edit(BuildContext context, [Json? document]) => showDialog<void>(
    context: context,
    builder: (_) => _ChartEditor(app: app, document: document),
  );

  @override
  Widget build(BuildContext context) {
    final documents = app.store
        .all('settings')
        .where((d) => d['custom_chart'] != null)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel(
          '내가 만든 지출 그래프',
          const Text('대분류·소분류를 원하는 묶음으로 합산합니다. 홈에서 선택한 월을 따라 바뀝니다.'),
          trailing: TextButton.icon(
            onPressed: () => edit(context),
            icon: const Icon(Icons.add_chart),
            label: const Text('그래프 추가'),
          ),
        ),
        for (final document in documents)
          Builder(
            builder: (context) {
              final chart = document['custom_chart'] as Json;
              final values = customChartTotals(app.store, month, chart);
              final largest = values.fold<int>(
                1,
                (v, e) => e.$2.abs() > v ? e.$2.abs() : v,
              );
              return panel(
                chart['name'] as String,
                spaced([
                  Text(
                    '$month · 합계 ${money(sumMoney(values.map((e) => e.$2)))}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  for (var i = 0; i < values.length; i++)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(values[i].$1)),
                            Text(
                              money(values[i].$2),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            minHeight: 12,
                            value: values[i].$2.abs() / largest,
                            color: values[i].$2 < 0
                                ? Theme.of(context).colorScheme.error
                                : chartColors[i % chartColors.length],
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ),
                  const Text(
                    '환불을 차감한 지출입니다. 음수는 환불이 지출보다 큰 금액이며 막대는 절댓값입니다.',
                    style: TextStyle(fontSize: 12),
                  ),
                ]),
                trailing: PopupMenuButton<String>(
                  tooltip: '그래프 관리',
                  onSelected: (action) async {
                    if (action == 'edit') {
                      await edit(context, document);
                    } else if (await confirm(
                      context,
                      '그래프 삭제',
                      '이 그래프의 구성만 삭제합니다. 실제 거래는 유지됩니다.',
                    )) {
                      try {
                        final current = app.store.get(
                          'settings',
                          document['id'] as String,
                        );
                        require(
                          current != null &&
                              digest(current) == digest(document),
                          '그래프가 변경됐어요. 다시 확인해 주세요.',
                        );
                        app.store.save('settings', {
                          ...document,
                          'deleted': true,
                        });
                        app.changed();
                      } catch (e) {
                        if (context.mounted) message(context, e);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('구성 수정')),
                    PopupMenuItem(value: 'delete', child: Text('그래프 삭제')),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

class _ChartEditor extends StatefulWidget {
  final AppController app;
  final Json? document;
  const _ChartEditor({required this.app, this.document});
  @override
  State<_ChartEditor> createState() => _ChartEditorState();
}

class _ChartEditorState extends State<_ChartEditor> {
  late final TextEditingController name;
  late final List<Json> groups;
  late bool other;
  String? error;
  @override
  void initState() {
    super.initState();
    final chart = widget.document?['custom_chart'] as Json?;
    name = TextEditingController(text: chart?['name'] as String? ?? '');
    groups = chart == null ? [] : rows(jsonDecode(jsonEncode(chart['groups'])));
    other = chart?['other'] as bool? ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> group([int? index]) async {
    final result = await showDialog<Json>(
      context: context,
      builder: (_) => _GroupEditor(
        app: widget.app,
        initial: index == null ? null : groups[index],
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        groups.add(result);
      } else {
        groups[index] = result;
      }
      error = null;
    });
  }

  void save() {
    try {
      final chart = <String, dynamic>{
        'name': name.text.trim(),
        'groups': groups,
        'other': other,
      };
      validateCustomChart(chart);
      final old = widget.document;
      if (old != null) {
        final current = widget.app.store.get('settings', old['id'] as String);
        require(
          current != null && digest(current) == digest(old),
          '다른 화면에서 변경됐어요. 닫고 다시 열어 주세요.',
        );
      }
      widget.app.store.save('settings', {
        'id': old?['id'] ?? uuid.v4(),
        'custom_chart': chart,
      });
      widget.app.changed();
      Navigator.pop(context);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('지출 그래프 구성'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: spaced([
          TextField(
            controller: name,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '그래프 이름',
              hintText: '예: 생활비 구성',
            ),
          ),
          const Text(
            '묶음마다 대분류 전체 또는 특정 소분류를 선택하세요. 분류는 한 그래프 안에서 한 번만 사용할 수 있습니다.',
          ),
          for (var i = 0; i < groups.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(groups[i]['name'] as String),
              subtitle: Text(
                rows(groups[i]['selectors'])
                    .map((s) => '${s['category']} › ${s['sub'] ?? '전체'}')
                    .join(', '),
              ),
              onTap: () => group(i),
              trailing: IconButton(
                tooltip: '묶음 삭제',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => groups.removeAt(i)),
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => group(),
            icon: const Icon(Icons.add),
            label: const Text('묶음 추가'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('선택하지 않은 분류는 ‘그 외’로 표시'),
            value: other,
            onChanged: (v) => setState(() => other = v),
          ),
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
      FilledButton(onPressed: save, child: const Text('그래프 저장')),
    ],
  );
}

Future<List<Json>?> chooseBudgetCategories(
  BuildContext context,
  AppController app,
  List<Json> selected,
) async {
  final result = await showDialog<Json>(
    context: context,
    builder: (_) => _GroupEditor(
      app: app,
      selectionOnly: true,
      initial: {'name': '예산 대상', 'selectors': selected},
    ),
  );
  return result == null ? null : rows(result['selectors']);
}

class _GroupEditor extends StatefulWidget {
  final AppController app;
  final Json? initial;
  final bool selectionOnly;
  const _GroupEditor({
    required this.app,
    this.initial,
    this.selectionOnly = false,
  });
  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final TextEditingController name;
  late final List<Json> selectors;
  late final Map<String, Set<String>> categories;
  String? error;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(
      text: widget.initial?['name'] as String? ?? '',
    );
    selectors = rows(
      widget.initial?['selectors'],
    ).map((s) => <String, dynamic>{...s}).toList();
    categories = {};
    final all = widget.app.store.all('category');
    for (final c in all.where(
      (c) =>
          c['parent'] == null && ['expense', 'settlement'].contains(c['type']),
    )) {
      categories
          .putIfAbsent(c['name'] as String, () => <String>{})
          .addAll(
            all
                .where((child) => child['parent'] == c['id'])
                .map((child) => child['name'] as String),
          );
    }
    for (final row in widget.app.store.query(
      "SELECT DISTINCT a.category_name, a.subcategory_name FROM transaction_allocations a JOIN transactions t ON t.id=a.transaction_id WHERE t.type IN ('expense','refund')",
    )) {
      final cat = row['category_name'] as String;
      categories
          .putIfAbsent(cat, () => <String>{})
          .add(row['subcategory_name'] as String? ?? '');
    }
    for (final s in selectors) {
      categories.putIfAbsent(s['category'] as String, () => <String>{});
      if (s['sub'] != null) categories[s['category']]!.add(s['sub'] as String);
    }
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  bool selected(String cat, String? sub) =>
      selectors.any((s) => s['category'] == cat && s['sub'] == sub);
  Widget choice(String cat, String? sub) => CheckboxListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(
      sub == null
          ? '$cat 전체'
          : sub.isEmpty
          ? '소분류 없음'
          : sub,
    ),
    value: selected(cat, sub),
    onChanged: (value) => setState(() {
      selectors.removeWhere(
        (s) =>
            s['category'] == cat &&
            (s['sub'] == sub ||
                (value == true && (sub == null || s['sub'] == null))),
      );
      if (value == true) selectors.add({'category': cat, 'sub': sub});
    }),
  );
  @override
  Widget build(BuildContext context) {
    final names = categories.keys.toList()..sort();
    return AlertDialog(
      title: Text(widget.selectionOnly ? '예산 카테고리 선택' : '분류 묶음'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: spaced([
            if (!widget.selectionOnly)
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: '묶음 이름',
                  hintText: '예: 생활 필수액, 여비',
                ),
              ),
            for (final cat in names)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(cat),
                subtitle: Text(
                  '${selectors.where((s) => s['category'] == cat).length}개 선택',
                ),
                children: [
                  choice(cat, null),
                  for (final sub in (categories[cat]!.toList()..sort()))
                    choice(cat, sub),
                ],
              ),
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
            final result = <String, dynamic>{
              'name': name.text.trim(),
              'selectors': selectors,
            };
            try {
              validateCustomChart({
                'name': '검증',
                'groups': [result],
                'other': false,
              });
              Navigator.pop(context, result);
            } catch (e) {
              setState(() => error = '$e');
            }
          },
          child: Text(widget.selectionOnly ? '선택 적용' : '묶음 적용'),
        ),
      ],
    );
  }
}
