import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../domain/value.dart';
import 'common.dart';
import 'money_input.dart';

class EntrySaveResult {
  final String? transactionId;
  const EntrySaveResult(this.transactionId);
}

class EntryEditor extends StatefulWidget {
  final AppController app;
  final String initialType;
  final String? initialDate;
  final String? initialAccount;
  final Json? existing;
  final bool recurring;
  final bool copy;
  final String? ruleId;
  const EntryEditor({
    super.key,
    required this.app,
    this.initialType = 'expense',
    this.initialDate,
    this.initialAccount,
    this.existing,
    this.recurring = false,
    this.copy = false,
    this.ruleId,
  });
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late Json draft;
  late final TextEditingController amount, memo, person, shareAmount;
  String? error;
  bool saving = false;
  bool get persistent => widget.existing == null && widget.ruleId == null;
  String get type => draft['type'] as String;
  bool get recurring => draft['recurring'] == true;
  List<Json> get accounts => widget.app.store
      .all('account')
      .where((a) => a['archived'] != true || widget.existing != null)
      .toList();
  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final allocation = e == null ? null : rows(e['allocations']).firstOrNull;
    final now = today();
    final requestedDate = widget.initialDate ?? now;
    final initialDate = widget.recurring || requestedDate.compareTo(now) <= 0
        ? requestedDate
        : now;
    draft = {
      'type': widget.initialType,
      'recurring': widget.recurring,
      'date': initialDate,
      'amount': '',
      'memo': '',
      'account': accounts.any((a) => a['id'] == widget.initialAccount)
          ? widget.initialAccount
          : accounts.firstOrNull?['id'],
      'cycle': 'monthly',
      'direction': 'lent',
      'shares': <Json>[],
      'cash': false,
      'receipt': false,
    };
    if (e != null) {
      draft.addAll({
        'type': e['type'],
        'amount': '${e['amount']}',
        'memo': e['memo'],
        'date': e['date'] ?? e['start'],
        'account': e['account'] ?? rows(e['postings']).firstOrNull?['account'],
        'destination':
            e['destination'] ??
            (rows(e['postings']).length > 1
                ? rows(e['postings']).last['account']
                : null),
        'category': allocation?['category_id'] ?? e['category_id'],
        'subcategory': allocation?['subcategory_id'] ?? e['subcategory_id'],
        'category_name': allocation?['category_name'] ?? e['category_name'],
        'subcategory_name':
            allocation?['subcategory_name'] ?? e['subcategory_name'],
        'shares': rows(e['shares']),
        'cycle': e['cycle'] ?? 'monthly',
        'end': e['end'],
      });
      if (widget.copy) {
        draft['date'] = initialDate;
        draft['shares'] = <Json>[];
      }
    }
    if (persistent) {
      final saved = widget.app.store.local('entry_draft');
      if (saved != null) {
        try {
          draft = jsonDecode(saved) as Json;
        } catch (_) {
          widget.app.store.removeLocal('entry_draft');
        }
      }
    }
    amount = TextEditingController(
      text: const MoneyInputFormatter().format(
        draft['amount'] as String? ?? '',
      ),
    );
    memo = TextEditingController(text: draft['memo'] as String? ?? '');
    person = TextEditingController(text: draft['person'] as String? ?? '');
    shareAmount = TextEditingController();
    amount.addListener(() => update('amount', amount.text, rebuild: false));
    memo.addListener(() => update('memo', memo.text, rebuild: false));
    person.addListener(() => update('person', person.text, rebuild: false));
  }

  void persist() {
    if (persistent) widget.app.store.setLocal('entry_draft', jsonEncode(draft));
  }

  void update(String key, dynamic value, {bool rebuild = true}) {
    draft[key] = value;
    persist();
    if (rebuild) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [amount, memo, person, shareAmount]) {
      c.dispose();
    }
    super.dispose();
  }

  List<(String, String)> accountOptions() =>
      accounts.map((a) => (a['id'] as String, a['name'] as String)).toList();
  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final service = widget.app.service;
      if (widget.existing != null && widget.ruleId == null && !widget.copy) {
        require(
          digest(
                widget.app.store.get('entry', widget.existing!['id'] as String),
              ) ==
              digest(widget.existing),
          '편집 중 다른 기기에서 변경된 내역입니다. 닫았다가 다시 열어 주세요.',
        );
      }
      final value = parseMoney(amount.text);
      positiveMoney(value);
      final on = draft['date'] as String, account = draft['account'] as String?;
      String? savedId;
      if (type == 'debt') {
        final debtId = service.createDebt(
          person: person.text,
          direction: draft['direction'] as String,
          amount: value,
          on: on,
          account: draft['cash'] == true ? account : null,
          due: draft['due'] as String?,
          memo: memo.text,
        );
        if (draft['cash'] == true) {
          savedId =
              rows(widget.app.store.get('debt', debtId)!['events']).first['id']
                  as String;
        }
      } else if (type == 'income' && draft['receipt'] == true && !recurring) {
        require(draft['claim'] != null, '정산할 상대방을 선택해 주세요.');
        final claim = (draft['claim'] as String).split('/');
        require(account != null, '입금 계좌를 선택해 주세요.');
        service.receive(claim[0], claim[1], value, account!, on);
        savedId =
            rows(
                  widget.app.store.get('entry', claim[0])!['receipts'],
                ).last['id']
                as String;
      } else {
        require(account != null, '계좌를 먼저 등록해 주세요.');
        final categories = widget.app.store.all('category');
        final category = categories
            .where((c) => c['id'] == draft['category'])
            .firstOrNull;
        final sub = categories
            .where((c) => c['id'] == draft['subcategory'])
            .firstOrNull;
        final selectedName = draft['category_name'] ?? category?['name'];
        final catName = selectedName == '' ? null : selectedName;
        require(type == 'transfer' || catName != null, '대분류를 선택해 주세요.');
        final alloc = service.allocation(
          value,
          catName as String? ?? '',
          subcategory:
              draft['subcategory_name'] as String? ?? sub?['name'] as String?,
          categoryId:
              category?['id'] as String? ??
              (widget.existing != null ? draft['category'] as String? : null),
          subcategoryId:
              sub?['id'] as String? ??
              (widget.existing != null
                  ? draft['subcategory'] as String?
                  : null),
        );
        if (recurring) {
          final start = date(on);
          final ruleId = service.saveRule({
            ...alloc,
            'type': type,
            'account': account,
            'destination': draft['destination'],
            'memo': memo.text,
            'cycle': draft['cycle'],
            'start': on,
            'effective': on,
            'anchor_day': start.day,
            'anchor_month': start.month,
            'end': draft['end'],
          }, ruleId: widget.ruleId);
          final previousIds = widget.app.store
              .all('entry')
              .map((e) => e['id'])
              .toSet();
          service.generateDue();
          savedId =
              widget.app.store
                      .entries()
                      .where(
                        (e) =>
                            !previousIds.contains(e['id']) &&
                            widget.app.store.get(
                                  'entry',
                                  e['id'] as String,
                                )?['rule'] ==
                                ruleId,
                      )
                      .firstOrNull?['id']
                  as String?;
        } else {
          final shares = type == 'expense' ? rows(draft['shares']) : <Json>[];
          alloc['amount'] =
              value - sumMoney(shares.map((s) => s['amount'] as int));
          require(alloc['amount'] >= 0, '상대방 몫의 합계가 결제액보다 커요.');
          final e = service.makeEntry(
            id: widget.copy ? null : widget.existing?['id'] as String?,
            type: type,
            amount: value,
            account: account!,
            destination: draft['destination'] as String?,
            on: on,
            memo: memo.text,
            allocations: type == 'transfer' && catName == null ? [] : [alloc],
            shares: shares,
          );
          if (widget.existing != null && !widget.copy) {
            for (final key in [
              'receipts',
              'refunds',
              'rule',
              'rule_revision',
              'scheduled_on',
              'import_key',
            ]) {
              if (widget.existing!.containsKey(key)) {
                e[key] = widget.existing![key];
              }
            }
          }
          service.saveEntry(e);
          savedId = e['id'] as String;
        }
      }
      if (persistent) widget.app.store.removeLocal('entry_draft');
      widget.app.changed();
      if (mounted) Navigator.pop(context, EntrySaveResult(savedId));
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.app.store
        .all('category')
        .where((c) => c['type'] == type)
        .toList();
    final main = categories
        .where((c) => c['parent'] == null)
        .map((c) => (c['id'] as String, c['name'] as String))
        .toList();
    final subs = categories
        .where((c) => c['parent'] != null && c['parent'] == draft['category'])
        .map((c) => (c['id'] as String, c['name'] as String))
        .toList();
    final claims = <(String, String)>[];
    for (final e in widget.app.store.all('entry')) {
      for (final s in rows(e['shares'])) {
        final left = widget.app.service.remainingShare(e, s);
        if (left > 0) {
          claims.add((
            '${e['id']}/${s['id']}',
            '${s['person']} · ${money(left)} · ${e['date']}',
          ));
        }
      }
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: spaced([
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.ruleId != null
                        ? '정기 내역 변경'
                        : widget.copy
                        ? '내역 복사'
                        : widget.existing != null
                        ? '내역 수정'
                        : '내역 추가',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '닫기 · 작성 내용 보관',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (persistent && widget.app.store.local('entry_draft') != null)
              const Text(
                '작성 내용은 이 기기에 임시 저장됩니다.',
                style: TextStyle(fontSize: 12),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in ['expense', 'income', 'transfer', 'debt'])
                  ChoiceChip(
                    label: Text(t == 'debt' ? '빚' : typeLabels[t]!),
                    selected: type == t,
                    onSelected: widget.existing != null
                        ? null
                        : (_) {
                            draft['category'] = null;
                            draft['subcategory'] = null;
                            draft['category_name'] = null;
                            draft['subcategory_name'] = null;
                            if (t == 'debt') draft['recurring'] = false;
                            update('type', t);
                          },
                  ),
              ],
            ),
            if (type != 'debt')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('정기 내역으로 등록'),
                subtitle: const Text('수입·지출·이동을 매월 또는 매년 반복'),
                value: recurring,
                onChanged: widget.existing != null
                    ? null
                    : (v) => update('recurring', v),
              ),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: const [MoneyInputFormatter()],
              decoration: const InputDecoration(
                labelText: '금액',
                suffixText: '원',
              ),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final on = await pickDay(
                  context,
                  draft['date'] as String,
                  future: recurring,
                );
                if (on != null) update('date', on);
              },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text('${recurring ? '첫 적용일' : '날짜'}  ${draft['date']}'),
            ),
            if (type == 'debt') ...[
              selectField('종류', draft['direction'] as String, [
                ('lent', '빌려준 돈'),
                ('borrowed', '빌린 돈'),
              ], (v) => update('direction', v)),
              TextField(
                controller: person,
                decoration: const InputDecoration(labelText: '상대방'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('실제 계좌 입출금도 기록'),
                subtitle: const Text('원금은 수입·지출 집계에서 제외'),
                value: draft['cash'] == true,
                onChanged: (v) => update('cash', v),
              ),
              if (draft['cash'] == true)
                selectField(
                  '연결 계좌',
                  draft['account'] as String?,
                  accountOptions(),
                  (v) => update('account', v),
                ),
              OutlinedButton(
                onPressed: () async {
                  final on = await pickDay(
                    context,
                    draft['due'] as String? ?? today(),
                    future: true,
                  );
                  if (on != null) update('due', on);
                },
                child: Text('상환 예정일  ${draft['due'] ?? '선택 안 함'}'),
              ),
            ] else ...[
              selectField(
                type == 'transfer' ? '출발 계좌' : '계좌',
                draft['account'] as String?,
                accountOptions(),
                (v) => update('account', v),
              ),
              if (type == 'transfer')
                selectField(
                  '도착 계좌',
                  draft['destination'] as String?,
                  accountOptions(),
                  (v) => update('destination', v),
                ),
              if (type == 'income' &&
                  !recurring &&
                  widget.existing == null &&
                  claims.isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('기존 방식 정산금 받기'),
                  subtitle: const Text('계좌 잔액에 반영하고 수입에서 제외'),
                  value: draft['receipt'] == true,
                  onChanged: (v) => update('receipt', v),
                ),
              if (type == 'income' && draft['receipt'] == true && !recurring)
                selectField(
                  '정산 상대방',
                  draft['claim'] as String?,
                  claims,
                  (v) => update('claim', v),
                )
              else ...[
                selectField(
                  type == 'transfer' ? '대분류 (선택)' : '대분류',
                  draft['category'] as String?,
                  [if (type == 'transfer') ('', '선택 안 함'), ...main],
                  (v) {
                    draft['subcategory'] = null;
                    draft['subcategory_name'] = null;
                    draft['category_name'] = null;
                    update('category', v == '' ? null : v);
                  },
                ),
                selectField(
                  '소분류 (선택)',
                  draft['subcategory'] as String? ?? '',
                  [('', '선택 안 함'), ...subs],
                  (v) {
                    draft['subcategory_name'] = null;
                    update('subcategory', v == '' ? null : v);
                  },
                ),
                if (!main.any((c) => c.$1 == draft['category']) &&
                    draft['category_name'] != null)
                  Text(
                    '기존 분류 유지: ${draft['category_name']} / ${draft['subcategory_name'] ?? ''}',
                  ),
              ],
            ],
            TextField(
              controller: memo,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '메모 (선택)',
                isDense: true,
              ),
            ),
            if (type != 'debt')
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('카테고리 추가'),
                  onPressed: () async {
                    final parents = widget.app.store
                        .all('category')
                        .where((c) => c['type'] == type && c['parent'] == null)
                        .map((c) => (c['id'] as String, c['name'] as String))
                        .toList();
                    final v = await prompt(context, '카테고리 추가', [
                      PromptField(
                        'parent',
                        '분류 위치',
                        initial: '',
                        options: [('', '새 대분류'), ...parents],
                      ),
                      const PromptField('name', '이름'),
                    ]);
                    if (v != null && context.mounted) {
                      try {
                        widget.app.service.saveCategory(
                          type,
                          v['name'] as String,
                          parent: v['parent'] == ''
                              ? null
                              : v['parent'] as String,
                        );
                        widget.app.changed();
                        setState(() {});
                      } catch (e) {
                        message(context, e);
                      }
                    }
                  },
                ),
              ),
            if (recurring) ...[
              selectField('반복 주기', draft['cycle'] as String, [
                ('monthly', '매월'),
                ('yearly', '매년'),
              ], (v) => update('cycle', v)),
              const Text(
                '적금은 입출금 계좌 → 적금 계좌의 정기 이동으로 등록하세요. 해당 일이 없는 달에는 말일에 반영합니다.',
                style: TextStyle(fontSize: 12),
              ),
              OutlinedButton(
                onPressed: () async {
                  final on = await pickDay(
                    context,
                    draft['end'] as String? ?? draft['date'] as String,
                    future: true,
                  );
                  if (on != null) update('end', on);
                },
                child: Text('종료일  ${draft['end'] ?? '없음'}'),
              ),
              if (draft['end'] != null)
                TextButton(
                  onPressed: () => update('end', null),
                  child: const Text('종료일 해제'),
                ),
            ],
            if (type == 'expense' &&
                !recurring &&
                rows(draft['shares']).isNotEmpty) ...[
              const Divider(),
              const Text(
                '기존 방식 정산 · 상대방 몫',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final s in rows(draft['shares']))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s['person'] as String),
                  subtitle: Text(money(s['amount'] as int)),
                  trailing: IconButton(
                    tooltip: '상대방 제외',
                    onPressed: () {
                      draft['shares'] = rows(
                        draft['shares'],
                      ).where((x) => x['id'] != s['id']).toList();
                      update('shares', draft['shares']);
                    },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: person,
                      decoration: const InputDecoration(labelText: '상대방'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: shareAmount,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [MoneyInputFormatter()],
                      decoration: const InputDecoration(labelText: '상대방 몫'),
                    ),
                  ),
                  IconButton(
                    tooltip: '정산 상대방 추가',
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () {
                      try {
                        require(person.text.trim().isNotEmpty, '상대방을 입력해 주세요.');
                        final n = parseMoney(shareAmount.text);
                        positiveMoney(n);
                        update('shares', [
                          ...rows(draft['shares']),
                          {
                            'id': uuid.v4(),
                            'person': person.text.trim(),
                            'amount': n,
                          },
                        ]);
                        person.clear();
                        shareAmount.clear();
                      } catch (e) {
                        message(context, e);
                      }
                    },
                  ),
                ],
              ),
              Text(
                '상대방 몫: ${money(sumMoney(rows(draft['shares']).map((s) => s['amount'] as int)))} · 내 부담만 지출로 집계합니다.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            FilledButton.icon(
              onPressed: saving ? null : save,
              icon: const Icon(Icons.check),
              label: Text(saving ? '저장 중…' : '저장'),
            ),
            if (persistent)
              TextButton(
                onPressed: () async {
                  if (await confirm(
                    context,
                    '작성 내용 지우기',
                    '임시 저장된 입력 내용을 지웁니다.',
                  )) {
                    widget.app.store.removeLocal('entry_draft');
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                child: const Text('작성 내용 지우기'),
              ),
          ]),
        ),
      ),
    );
  }
}
