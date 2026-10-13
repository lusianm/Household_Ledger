import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../data/ledger_store.dart';
import '../domain/settlement_service.dart';
import '../domain/value.dart';
import 'common.dart';

Future<void> showSettlement(
  BuildContext context,
  AppController app, {
  String? id,
}) => showDialog<void>(
  context: context,
  builder: (_) => SettlementEditor(app: app, id: id),
);

class SettlementEditor extends StatefulWidget {
  final AppController app;
  final String? id;
  const SettlementEditor({super.key, required this.app, this.id});
  @override
  State<SettlementEditor> createState() => _SettlementEditorState();
}

class _SettlementEditorState extends State<SettlementEditor> {
  AppController get app => widget.app;
  late Json draft;
  late TextEditingController name, memo;
  String? base, error;
  bool dateEdited = false;
  bool get closed => draft['closed'] == true;
  @override
  void initState() {
    super.initState();
    final old = widget.id == null
        ? null
        : app.store.get('settlement_group', widget.id!);
    base = old == null ? null : digest(old);
    draft =
        old ??
        {
          'id': uuid.v4(),
          'name': '',
          'date': today(),
          'memo': '',
          'category_name': '기타',
          'subcategory_name': null,
          'members': <String>[],
          'claims': <Json>[],
          'closed': false,
        };
    name = TextEditingController(text: draft['name'] as String);
    memo = TextEditingController(text: draft['memo'] as String);
  }

  @override
  void dispose() {
    name.dispose();
    memo.dispose();
    super.dispose();
  }

  bool save() {
    try {
      final current = app.store.get('settlement_group', draft['id'] as String);
      require(
        (base == null && current == null) ||
            (current != null && digest(current) == base),
        '다른 화면이나 기기에서 정산이 변경됐어요. 닫고 다시 열어 주세요.',
      );
      draft['name'] = name.text.trim();
      draft['memo'] = memo.text;
      final categories = app.store.all('category');
      final parent = categories
          .where(
            (c) =>
                c['type'] == 'settlement' &&
                c['parent'] == null &&
                c['name'] == draft['category_name'],
          )
          .firstOrNull;
      if (parent != null) {
        draft['category_id'] = parent['id'];
      } else {
        draft.remove('category_id');
      }
      final child = categories
          .where(
            (c) =>
                parent != null &&
                c['parent'] == parent['id'] &&
                c['name'] == draft['subcategory_name'],
          )
          .firstOrNull;
      if (child != null) {
        draft['subcategory_id'] = child['id'];
      } else {
        draft.remove('subcategory_id');
      }
      draft['members'] = (draft['members'] as List).cast<String>()..sort();
      app.service.saveSettlement(draft);
      base = digest(draft);
      app.changed();
      return true;
    } catch (e) {
      setState(() => error = '$e');
      return false;
    }
  }

  Future<void> chooseMembers() async {
    final selected = (draft['members'] as List).cast<String>().toSet();
    var filter = '';
    String? account;
    final eligible =
        app.store
            .all('entry')
            .where(
              (e) =>
                  LedgerStore.canGroup(e) &&
                  (app.store.settlementFor(e['id'] as String) == null ||
                      app.store.settlementFor(e['id'] as String)?['id'] ==
                          draft['id']),
            )
            .toList()
          ..sort(
            (a, b) => '${b['date']} ${b['memo']}'.compareTo(
              '${a['date']} ${a['memo']}',
            ),
          );
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          final shown = eligible
              .where(
                (e) =>
                    '${e['date']} ${e['memo']} ${entryLabel(e)}'.contains(
                      filter,
                    ) &&
                    (account == null ||
                        rows(
                          e['postings'],
                        ).any((p) => p['account'] == account)),
              )
              .toList();
          return AlertDialog(
            title: Text('연결할 내역 · ${selected.length}건 선택'),
            content: SizedBox(
              width: 620,
              height: 450,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '전체 기간에서 날짜·메모·분류 검색',
                    ),
                    onChanged: (v) => update(() => filter = v),
                  ),
                  selectField('계좌', account ?? '', [
                    ('', '전체 계좌'),
                    for (final a in app.store.all('account'))
                      (a['id'] as String, a['name'] as String),
                  ], (v) => update(() => account = v == '' ? null : v)),
                  const Text('일반 수입·지출을 여러 개 선택하세요. 이동·기존 정산·환불 연결 거래는 제외합니다.'),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final e = shown[i], id = e['id'] as String;
                        return CheckboxListTile(
                          value: selected.contains(id),
                          title: Text(
                            '${e['date']} · ${typeLabels[e['type']]} ${money(e['amount'] as int)}',
                          ),
                          subtitle: Text('${e['memo']} · ${entryLabel(e)}'),
                          onChanged: (v) => update(() {
                            v == true ? selected.add(id) : selected.remove(id);
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('선택 적용'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      draft['members'] = selected.toList()..sort();
      if (base == null && !dateEdited && selected.isNotEmpty) {
        final dates =
            eligible
                .where((e) => selected.contains(e['id']))
                .map((e) => e['date'] as String)
                .toList()
              ..sort();
        draft['date'] = dates.last;
      }
    });
  }

  Future<void> addClaim() async {
    final v = await prompt(context, '받을 돈 메모', [
      PromptField('person', '상대방'),
      PromptField('amount', '받을 금액', money: true),
      PromptField('memo', '메모'),
    ], note: '체크 여부는 실제 입출금이나 정산 합계에 영향을 주지 않습니다.');
    if (v == null || !mounted) return;
    try {
      final amount = parseMoney(v['amount'] as String);
      positiveMoney(amount);
      require((v['person'] as String).trim().isNotEmpty, '상대방을 입력해 주세요.');
      setState(
        () => draft['claims'] = [
          ...rows(draft['claims']),
          {
            'id': uuid.v4(),
            'person': (v['person'] as String).trim(),
            'amount': amount,
            'memo': v['memo'],
            'received': false,
          },
        ],
      );
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> addCategory({bool child = false}) async {
    final parent = app.store
        .all('category')
        .where(
          (c) =>
              c['type'] == 'settlement' &&
              c['parent'] == null &&
              c['name'] == draft['category_name'],
        )
        .firstOrNull;
    if (child && parent == null) {
      setState(() => error = '대분류를 먼저 카테고리에 등록해 주세요.');
      return;
    }
    final v = await prompt(context, child ? '정산 소분류 추가' : '정산 대분류 추가', [
      PromptField('name', '분류 이름'),
    ]);
    if (v == null || !mounted) return;
    try {
      app.service.saveCategory(
        'settlement',
        v['name'] as String,
        parent: child ? parent!['id'] as String : null,
      );
      setState(() {
        draft[child ? 'subcategory_name' : 'category_name'] =
            (v['name'] as String).trim();
        if (!child) draft['subcategory_name'] = null;
      });
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final totals = app.store.settlementTotals(draft),
        net = totals['net'] as int;
    final categories = app.store
        .all('category')
        .where((c) => c['type'] == 'settlement')
        .toList();
    final parent = categories
        .where(
          (c) => c['parent'] == null && c['name'] == draft['category_name'],
        )
        .firstOrNull;
    final children = categories
        .where((c) => parent != null && c['parent'] == parent['id'])
        .toList();
    final claims = rows(draft['claims']);
    final members = (draft['members'] as List).cast<String>();
    final periods =
        members
            .map((id) => app.store.get('entry', id))
            .whereType<Json>()
            .where((e) => e['deleted'] != true)
            .map((e) => monthOf(e['date'] as String))
            .toSet()
            .toList()
          ..sort();
    return AlertDialog(
      title: Text(widget.id == null ? '정산 묶음 만들기' : '정산 묶음'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: spaced([
            if (app.store.pending.any(
              (p) => p.startsWith('settlement_group/${draft['id']}:'),
            ))
              const Text(
                '연결을 확인해야 합니다. 누락된 기록을 동기화하거나 다른 정산과 중복된 연결을 해제해 주세요. 확인 전에는 묶음 통계를 적용하지 않습니다.',
              ),
            Text(
              '자동 계산 · ${net > 0
                  ? '순수입'
                  : net < 0
                  ? '순지출'
                  : '차액 없음'} ${money(net.abs())}',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
                color: net > 0 ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
            Text(
              '연결 입금 ${money(totals['income'] as int)} − 연결 출금 ${money(totals['expense'] as int)}',
            ),
            TextField(
              controller: name,
              enabled: !closed,
              decoration: const InputDecoration(labelText: '정산 이름'),
            ),
            Row(
              children: [
                Expanded(
                  child: selectField(
                    '정산 대분류',
                    draft['category_name'] as String,
                    {
                      draft['category_name'] as String,
                      '기타',
                      ...categories
                          .where((c) => c['parent'] == null)
                          .map((c) => c['name'] as String),
                    }.map((v) => (v, v)).toList(),
                    (v) {
                      if (!closed) {
                        setState(() {
                          draft['category_name'] = v;
                          draft['subcategory_name'] = null;
                        });
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: '대분류 추가',
                  onPressed: closed ? null : () => addCategory(),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: selectField(
                    '정산 소분류 (선택)',
                    draft['subcategory_name'] as String? ?? '',
                    {
                      '',
                      if (draft['subcategory_name'] != null)
                        draft['subcategory_name'] as String,
                      ...children.map((c) => c['name'] as String),
                    }.map((v) => (v, v.isEmpty ? '선택 안 함' : v)).toList(),
                    (v) {
                      if (!closed) {
                        setState(
                          () => draft['subcategory_name'] = v == '' ? null : v,
                        );
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: '소분류 추가',
                  onPressed: closed ? null : () => addCategory(child: true),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            TextField(
              controller: memo,
              enabled: !closed,
              decoration: const InputDecoration(labelText: '메모'),
            ),
            OutlinedButton(
              onPressed: closed
                  ? null
                  : () async {
                      final chosen = await pickDay(
                        context,
                        draft['date'] as String,
                      );
                      if (chosen != null && mounted) {
                        setState(() {
                          draft['date'] = chosen;
                          dateEdited = true;
                        });
                      }
                    },
              child: Text('통계 기준일 ${draft['date']}'),
            ),
            Text(
              '원래 거래는 계좌 잔액에 유지됩니다. ${periods.join(', ')}의 연결 내역은 개별 통계에서 제외하고, ${monthOf(draft['date'] as String)}에 순액을 한 번 반영합니다.',
            ),
            OutlinedButton.icon(
              onPressed: closed ? null : chooseMembers,
              icon: const Icon(Icons.checklist),
              label: Text('연결 내역 선택 · ${members.length}건'),
            ),
            ExpansionTile(
              title: const Text('연결된 원본 내역'),
              children: [
                for (final id in members)
                  Builder(
                    builder: (_) {
                      final e = app.store.get('entry', id);
                      return ListTile(
                        title: Text(
                          e == null
                              ? '수신 대기 중'
                              : '${e['date']} · ${typeLabels[e['type']]} ${money(e['amount'] as int)}${e['deleted'] == true ? ' (삭제됨 · 합계 제외)' : ''}',
                        ),
                        subtitle: Text(e?['memo'] as String? ?? id),
                        trailing: IconButton(
                          tooltip: '연결 해제',
                          onPressed: closed
                              ? null
                              : () => setState(
                                  () => draft['members'] = members
                                      .where((m) => m != id)
                                      .toList(),
                                ),
                          icon: const Icon(Icons.link_off),
                        ),
                      );
                    },
                  ),
              ],
            ),
            const Text('받을 돈 체크 · 실제 내역과 연결되지 않는 별도 기록'),
            for (final claim in claims)
              Column(
                children: [
                  CheckboxListTile(
                    value: claim['received'] == true,
                    title: Text(
                      '${claim['person']} · ${money(claim['amount'] as int)}',
                    ),
                    subtitle: Text(
                      '${claim['memo']}${claim['debt'] != null ? ' · 빚으로 이동됨' : ''}',
                    ),
                    onChanged: closed || claim['debt'] != null
                        ? null
                        : (v) => setState(() {
                            claim['received'] = v;
                            draft['claims'] = claims;
                          }),
                  ),
                  if (claim['debt'] == null)
                    Wrap(
                      children: [
                        if (claim['received'] != true)
                          TextButton(
                            onPressed: closed
                                ? null
                                : () async {
                                    if (!await confirm(
                                      context,
                                      '빚으로 이동',
                                      '현재 정산을 저장하고 받을 돈을 빚 관리에 추가합니다. 계좌 잔액은 바뀌지 않습니다.',
                                    )) {
                                      return;
                                    }
                                    if (!mounted || !save()) return;
                                    try {
                                      app.service.transferClaimToDebt(
                                        draft['id'] as String,
                                        claim['id'] as String,
                                      );
                                      setState(() {
                                        draft = app.store.get(
                                          'settlement_group',
                                          draft['id'] as String,
                                        )!;
                                        base = digest(draft);
                                      });
                                      app.changed();
                                    } catch (e) {
                                      setState(() => error = '$e');
                                    }
                                  },
                            child: const Text('빚으로 이동'),
                          ),
                        TextButton(
                          onPressed: closed
                              ? null
                              : () => setState(
                                  () => draft['claims'] = claims
                                      .where((c) => c['id'] != claim['id'])
                                      .toList(),
                                ),
                          child: const Text('항목 삭제'),
                        ),
                      ],
                    ),
                ],
              ),
            TextButton.icon(
              onPressed: closed ? null : addClaim,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('받을 돈 추가'),
            ),
            SwitchListTile(
              title: const Text('정산 마감'),
              subtitle: const Text('다시 열면 연결 내역과 받을 돈을 수정할 수 있습니다.'),
              value: closed,
              onChanged: (v) => setState(() => draft['closed'] = v),
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
        if (base != null)
          TextButton(
            onPressed: () async {
              if (!await confirm(
                context,
                '정산 묶음 삭제',
                '원본 거래와 이미 옮긴 빚은 남습니다. 원래 거래가 각 거래일의 수입·지출 통계에 다시 반영됩니다.',
              )) {
                return;
              }
              if (!mounted) return;
              try {
                require(
                  digest(
                        app.store.get(
                          'settlement_group',
                          draft['id'] as String,
                        ),
                      ) ==
                      base,
                  '변경된 정산입니다. 다시 열어 주세요.',
                );
                app.store.remove('settlement_group', draft['id'] as String);
                app.changed();
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                setState(() => error = '$e');
              }
            },
            child: const Text('묶음 삭제'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
        FilledButton(
          onPressed: () {
            if (save()) Navigator.pop(context);
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
