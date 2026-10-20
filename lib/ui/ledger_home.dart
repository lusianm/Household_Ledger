import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../platform/device.dart' as device;
import '../app_controller.dart';
import '../data/interchange.dart';
import '../domain/value.dart';
import '../sync/drive_sync.dart';
import 'common.dart';
import 'drive_folder_picker.dart';
import 'entry_editor.dart';
import 'settlement_editor.dart';
import 'custom_charts.dart';
import 'monthly_flow_chart.dart';
import 'budget_panel.dart';

class LedgerHome extends StatefulWidget {
  final AppController app;
  const LedgerHome({super.key, required this.app});
  @override
  State<LedgerHome> createState() => _LedgerHomeState();
}

class _LedgerHomeState extends State<LedgerHome> with WidgetsBindingObserver {
  AppController get app => widget.app;
  int tab = 0;
  String month = monthOf(today()),
      search = '',
      section = '',
      categoryFilter = '';
  String? accountFilter, selectedEntry;
  int listRevision = 0;
  bool annual = false, driveConnecting = false, recoveryAcknowledged = false;
  bool recurringAnnual = false;
  bool recurringFromStart = false;
  final searchInput = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      app.resume();
    });
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(refresh);
    searchInput.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) app.resume();
  }

  void act(void Function() action) {
    try {
      action();
      app.changed();
    } catch (e) {
      message(context, e);
    }
  }

  Future<void> add({
    String type = 'expense',
    bool recurring = false,
    bool copy = false,
    Json? existing,
    String? ruleId,
  }) async {
    final editingInLedger =
        tab == 1 && existing != null && !copy && !recurring && ruleId == null;
    final result = await showDialog<EntrySaveResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EntryEditor(
        app: app,
        initialType: type,
        initialDate: month == monthOf(today()) ? today() : '$month-01',
        initialAccount: tab == 1 ? accountFilter : null,
        recurring: recurring,
        copy: copy,
        existing: existing,
        ruleId: ruleId,
      ),
    );
    if (!mounted || result == null) return;
    final saved = app.store
        .entries()
        .where((e) => e['id'] == result.transactionId)
        .firstOrNull;
    setState(() {
      if (saved != null) {
        if (editingInLedger) {
          // Keep the current filters and list identity so edits retain scroll.
          selectedEntry = saved['id'] as String;
          return;
        }
        month = monthOf(saved['date'] as String);
        search = '';
        searchInput.clear();
        if (accountFilter != null &&
            app.store.query(
              'SELECT 1 FROM postings WHERE transaction_id=? AND account_id=?',
              [saved['id'], accountFilter],
            ).isEmpty) {
          accountFilter = null;
        }
        selectedEntry = saved['id'] as String;
        listRevision++;
        tab = 1;
        section = '';
      }
    });
  }

  List<(String, String)> get accountOptions => app.store
      .all('account')
      .map((a) => (a['id'] as String, a['name'] as String))
      .toList();
  String accountName(String? id) =>
      app.store.get('account', id ?? '')?['name'] as String? ?? '계좌 미연결';
  String get period => annual ? month.substring(0, 4) : month;
  List<(String, int)> breakdown(String filter, {String? parent}) {
    final column = parent == null
        ? 'category_name'
        : "COALESCE(subcategory_name,'소분류 없음')";
    final data = app.store.query(
      'SELECT $column label, SUM(a.amount) amount FROM transaction_allocations a JOIN transactions t ON t.id=a.transaction_id WHERE t.id NOT IN (SELECT transaction_id FROM settlement_members) AND t.date LIKE ? AND t.type IN (\'expense\',\'refund\') ${parent == null ? '' : 'AND category_name=?'} GROUP BY $column ORDER BY amount DESC',
      ['$filter%', ?parent],
    );
    return data.map((r) => (r['label'] as String, r['amount'] as int)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final title = [
      '차곡',
      '전체 내역',
      '계좌',
      '리포트',
      '정기 내역',
      '빚 관리',
      section.isEmpty ? '더보기' : section,
    ][tab];
    return Scaffold(
      appBar: AppBar(
        leading: tab == 6 && section.isNotEmpty
            ? IconButton(
                tooltip: '더보기',
                onPressed: () => setState(() => section = ''),
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: '화면 축소',
            visualDensity: VisualDensity.compact,
            onPressed: app.zoomPercent <= 70
                ? null
                : () => app.setZoom(app.zoomPercent - 10),
            icon: const Icon(Icons.remove),
          ),
          TextButton(
            onPressed: () => app.setZoom(100),
            child: Text('${app.zoomPercent}%'),
          ),
          IconButton(
            tooltip: '화면 확대',
            visualDensity: VisualDensity.compact,
            onPressed: app.zoomPercent >= 130
                ? null
                : () => app.setZoom(app.zoomPercent + 10),
            icon: const Icon(Icons.add),
          ),
          if (app.syncing)
            const Padding(
              padding: EdgeInsets.all(18),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: app.connected
                  ? '동기화 · 미전송 변경 ${app.store.unsent}건'
                  : '동기화 설정',
              icon: Icon(
                app.syncError != null
                    ? Icons.cloud_off_outlined
                    : app.connected
                    ? (app.store.unsent > 0
                          ? Icons.cloud_upload_outlined
                          : Icons.cloud_done_outlined)
                    : Icons.cloud_outlined,
              ),
              onPressed: () {
                if (app.connected) {
                  app.sync(interactive: true);
                } else {
                  setState(() {
                    tab = 6;
                    section = '설정';
                  });
                }
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (app.saving || app.dirty)
              const LinearProgressIndicator(minHeight: 2),
            if (!recoveryAcknowledged && device.deviceInfo()['notice'] != '')
              MaterialBanner(
                content: Text(device.deviceInfo()['notice'] as String),
                actions: [
                  TextButton(
                    onPressed: () =>
                        setState(() => recoveryAcknowledged = true),
                    child: const Text('확인'),
                  ),
                ],
              ),
            if (app.syncError != null)
              MaterialBanner(
                content: Text(
                  '${app.storageStatus} · ${app.syncError}',
                  maxLines: 3,
                ),
                actions: [
                  TextButton(
                    onPressed: () => app.sync(interactive: true),
                    child: const Text('재시도'),
                  ),
                ],
              ),
            if (app.store.conflicts.isNotEmpty || app.store.pending.isNotEmpty)
              MaterialBanner(
                content: Text(
                  '동기화 충돌 ${app.store.conflicts.length}건 · 연결 대기 ${app.store.pending.length}건',
                ),
                actions: [
                  TextButton(
                    onPressed: () => setState(() {
                      tab = 6;
                      section = '충돌 해결';
                    }),
                    child: const Text('확인'),
                  ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, b) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: b.maxWidth > 700 ? 24 : 12,
                      ),
                      child: switch (tab) {
                        0 => home(),
                        1 => ledger(b.maxWidth),
                        2 => accounts(),
                        3 => report(),
                        4 => rules(),
                        5 => debts(),
                        _ => more(),
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: tab == 0 || tab == 1
          ? FloatingActionButton.extended(
              onPressed: () => add(),
              icon: const Icon(Icons.add),
              label: const Text('내역 추가'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() {
          tab = i;
          selectedEntry = null;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: '내역',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: '계좌',
          ),
          NavigationDestination(
            icon: Icon(Icons.donut_large_outlined),
            label: '리포트',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_repeat),
            label: '정기',
            tooltip: '정기 내역 관리',
          ),
          NavigationDestination(
            icon: Icon(Icons.handshake_outlined),
            label: '빚',
            tooltip: '빚 관리',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: '더보기',
          ),
        ],
      ),
    );
  }

  Widget scroll(List<Widget> children) => ListView(
    key: ValueKey('page/$tab/$section'),
    padding: const EdgeInsets.only(top: 12, bottom: 100),
    children: [
      for (final w in children) ...[w, const SizedBox(height: 12)],
    ],
  );
  Widget monthPicker({bool year = false}) => Row(
    children: [
      IconButton(
        tooltip: '이전 ${year ? '해' : '달'}',
        onPressed: () => shiftMonth(year ? -12 : -1),
        icon: const Icon(Icons.chevron_left),
      ),
      Expanded(
        child: Center(
          child: Text(
            year
                ? '${month.substring(0, 4)}년'
                : '${month.substring(0, 4)}년 ${int.parse(month.substring(5))}월',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      IconButton(
        tooltip: '다음 ${year ? '해' : '달'}',
        onPressed: () => shiftMonth(year ? 12 : 1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  void shiftMonth(int by) {
    final d = date('$month-01');
    setState(() {
      month = monthOf(day(DateTime(d.year, d.month + by)));
      selectedEntry = null;
    });
  }

  Widget metric(String label, int value, {bool accent = false}) => Card(
    color: accent ? Theme.of(context).colorScheme.primary : null,
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: accent ? Colors.white70 : null,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              money(value),
              style: TextStyle(
                color: accent ? Colors.white : null,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  Widget home() {
    final accounts = app.store.all('account');
    final total = sumMoney(
      accounts
          .where((a) => a['kind'] != 'card')
          .map((a) => app.store.balance(a['id'] as String)),
    );
    final liquid = sumMoney(
      accounts
          .where(
            (a) =>
                a['liquid'] == true &&
                a['kind'] != 'card' &&
                a['kind'] != 'savings',
          )
          .map((a) => app.store.balance(a['id'] as String)),
    );
    final expense = app.store.flow(month, 'expense'),
        income = app.store.flow(month, 'income');
    final cards = [
      metric('전체 보유 금액', total, accent: true),
      metric('사용 가능 금액', liquid),
      metric('이번 달 지출', expense),
      metric('이번 달 수입', income),
    ];
    return scroll([
      monthPicker(),
      LayoutBuilder(
        builder: (c, b) {
          final columns = b.maxWidth >= 900 ? 4 : 2;
          return GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: columns,
            childAspectRatio: b.maxWidth / columns / 116,
            children: cards,
          );
        },
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '보유 금액은 현재 계좌 잔액입니다. 적금 포함 · 카드·빚·미수 정산금 제외',
          style: TextStyle(fontSize: 12),
        ),
      ),
      if (accounts.isEmpty)
        empty(
          '첫 계좌를 등록해 주세요',
          '통장·현금·적금·카드를 연결하면 잔액을 확인할 수 있어요.',
          action: FilledButton(
            onPressed: () => editAccount(),
            child: const Text('계좌 추가'),
          ),
        ),
      BudgetPanel(app: app, month: month),
      LayoutBuilder(
        builder: (c, b) {
          final chart = panel(
            '어디에 많이 썼을까요?',
            ExpenseChart(
              breakdown(month),
              onSelect: (name) => setState(() {
                categoryFilter = name;
                tab = 3;
              }),
            ),
          );
          final recent = panel(
            '최근 내역',
            Column(
              children: app.store
                  .entries(period: month, collapseSettlements: true)
                  .take(5)
                  .map(transactionTile)
                  .toList(),
            ),
            trailing: TextButton(
              onPressed: () => setState(() => tab = 1),
              child: const Text('전체 보기'),
            ),
          );
          return b.maxWidth >= 900
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: chart),
                    Expanded(flex: 2, child: recent),
                  ],
                )
              : Column(children: [chart, recent]);
        },
      ),
      homePlanning(),
      CustomCharts(app: app, month: month),
    ]);
  }

  Widget homePlanning() {
    final year = month.substring(0, 4);
    final debts = app.store.all('debt');
    final borrowed = sumMoney(
      debts
          .where((d) => d['direction'] == 'borrowed')
          .map(app.service.debtBalance),
    );
    final lent = sumMoney(
      debts.where((d) => d['direction'] == 'lent').map(app.service.debtBalance),
    );
    void openSection(String name) => setState(() {
      tab = name == '정기 내역' ? 4 : 5;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel(
          '월·연간 자금 계획',
          spaced([
            LayoutBuilder(
              builder: (context, constraints) {
                final monthly = forecastSummary(
                  month,
                  '${int.parse(month.substring(5))}월',
                );
                final yearly = forecastSummary(year, '$year년');
                return constraints.maxWidth >= 650
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: monthly),
                          const SizedBox(width: 32),
                          Expanded(child: yearly),
                        ],
                      )
                    : Column(
                        children: [monthly, const Divider(height: 32), yearly],
                      );
              },
            ),
            const Text(
              '지난 회차는 실제 기록, 오늘 이후 회차는 정기 일정의 예상 금액입니다. '
              '고정비는 정기 규칙과 연결된 지출만 포함합니다. '
              '운용 가능 금액은 수입에서 고정비를 뺀 금액이며 생활비·계좌 이동 전 기준입니다.',
              style: TextStyle(fontSize: 12),
            ),
            if (app.store.all('rule').isEmpty)
              const Text('정기 관리에서 규칙을 등록하면 앞으로의 예상 금액에 반영됩니다.'),
          ]),
          trailing: TextButton(
            onPressed: () => openSection('정기 내역'),
            child: const Text('정기 관리'),
          ),
        ),
        panel(
          '현재 남은 빚',
          spaced([
            summaryAmount('갚을 돈 총액', borrowed),
            summaryAmount('받을 돈 총액', lent),
            const Text(
              '상환·수령한 원금을 제외한 현재 잔액입니다. 선택한 월과 관계없이 표시합니다.',
              style: TextStyle(fontSize: 12),
            ),
            if (debts.isEmpty) const Text('등록된 빚이 없습니다. 빚 관리에서 등록해 주세요.'),
          ]),
          trailing: TextButton(
            onPressed: () => openSection('빚 관리'),
            child: const Text('빚 관리'),
          ),
        ),
      ],
    );
  }

  Widget summaryAmount(String label, int amount) => Row(
    children: [
      Expanded(child: Text(label)),
      Flexible(
        child: Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              money(amount),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    ],
  );

  Widget forecastSummary(String period, String label) {
    final totals = app.service.plannedFlow(period);
    final current = today().substring(0, period.length);
    final status = period.compareTo(current) < 0
        ? '실제 기록'
        : period == current
        ? '실제 + 남은 예상'
        : '예상';
    return Column(
      key: ValueKey('forecast/$period'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$label · $status',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        amountHighlight('수입 합계', totals['expected_income']!),
        const SizedBox(height: 8),
        amountHighlight('고정 지출', totals['expected_regular_expense']!),
        const SizedBox(height: 8),
        amountHighlight('고정비 제외 운용 가능', totals['available']!, incoming: true),
        const SizedBox(height: 12),
        summaryAmount('전체 지출 합계', totals['expected_expense']!),
        summaryAmount(
          '전체 지출 후 잔여액',
          totals['expected_income']! - totals['expected_expense']!,
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('실제·예상 금액 구분'),
          children: [
            summaryAmount('실제 수입', totals['actual_income']!),
            summaryAmount('실제 고정 지출', totals['actual_regular_expense']!),
            summaryAmount('실제 전체 지출', totals['actual_expense']!),
            summaryAmount('남은 예상 정기 수입', totals['future_income']!),
            summaryAmount('남은 예상 고정 지출', totals['future_expense']!),
            summaryAmount('정기 수입 합계', totals['expected_regular_income']!),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '미등록 생활비 등 앞으로의 변동 지출은 예측하지 않습니다.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget transactionTile(Json t) {
    final alloc = app.store.allocations(t['id'] as String);
    final balances = rows(t['balances']);
    final accountBalance = tab == 1 && accountFilter != null
        ? balances.where((b) => b['account_id'] == accountFilter).firstOrNull
        : null;
    final incoming = accountBalance != null
        ? (accountBalance['delta'] as int) > 0
        : t['type'] == 'income';
    final isGroup = (t['id'] as String).startsWith('settlement:');
    final group = t['group_id'] == null
        ? null
        : app.store.get('settlement_group', t['group_id'] as String);
    final title = isGroup
        ? '정산 · ${group?['name'] ?? ''}'
        : alloc.isEmpty
        ? (typeLabels[t['type']] ?? '내역')
        : entryLabel({'type': t['type'], 'allocations': alloc});
    return LayoutBuilder(
      builder: (context, constraints) => ListTile(
        key: ValueKey('transaction/${t['id']}'),
        selected: t['id'] == selectedEntry,
        selectedColor: Theme.of(context).colorScheme.primary,
        selectedTileColor: Theme.of(context).brightness == Brightness.light
            ? const Color(0xffd7f3fc)
            : const Color(0xff164556),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        isThreeLine: balances.isNotEmpty,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: constraints.maxWidth < 360
            ? null
            : CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  t['type'] == 'income'
                      ? Icons.south_west
                      : t['type'] == 'transfer'
                      ? Icons.swap_horiz
                      : Icons.north_east,
                  size: 19,
                ),
              ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${t['date']} · ${isGroup ? (t['amount'] == 0
                        ? '차액 없음'
                        : incoming
                        ? '순수입'
                        : '순지출') : t['memo'] ?? ''}${!isGroup && group != null ? ' · 정산: ${group['name']}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            if (balances.isNotEmpty)
              Text(
                balances
                    .map((b) => accountName(b['account_id'] as String))
                    .join(' → '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
          ],
        ),
        trailing: SizedBox(
          width: (constraints.maxWidth * 0.46).clamp(0, 220).toDouble(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  money(t['amount'] as int),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: incoming
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              if (balances.isNotEmpty) const SizedBox(height: 3),
              for (final b in balances.where(
                (b) => balances.length == 1 || (b['delta'] as int) > 0,
              ))
                Tooltip(
                  message:
                      '${accountName(b['account_id'] as String)} · 거래 후 잔액 ${money(b['balance_after'] as int)}',
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      money(b['balance_after'] as int),
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        onTap: () => openEntry(t),
      ),
    );
  }

  void openEntry(Json t) {
    setState(() => selectedEntry = t['id'] as String);
    if ((t['id'] as String).startsWith('settlement:')) {
      showSettlement(context, app, id: t['owner_id'] as String);
      return;
    }
    if (MediaQuery.sizeOf(context).width < 1000 || tab != 1) {
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: entryDetail(t, dialog: true),
            ),
          ),
        ),
      );
    }
  }

  Widget entryDetail(Json t, {bool dialog = false}) {
    if ((t['id'] as String).startsWith('settlement:')) {
      final group = app.store.get('settlement_group', t['owner_id'] as String)!;
      return spaced([
        Text(
          '정산 · ${group['name']}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text('${typeLabels[t['type']]} ${money(t['amount'] as int)}'),
        Text('기준일 ${group['date']} · 연결 ${(group['members'] as List).length}건'),
        FilledButton(
          onPressed: () =>
              showSettlement(context, app, id: group['id'] as String),
          child: const Text('정산 상세 열기'),
        ),
      ]);
    }
    final id = t['owner_id'] as String? ?? t['id'] as String;
    final e = app.store.get('entry', id);
    final debt = app.store.get('debt', id);
    final group = app.store.settlementFor(id);
    final primary = e != null && e['id'] == t['id'];
    void close() {
      if (dialog) Navigator.pop(context);
      setState(() => selectedEntry = null);
    }

    return spaced([
      if (group != null)
        TextButton(
          onPressed: () =>
              showSettlement(context, app, id: group['id'] as String),
          child: Text('정산 · ${group['name']}'),
        ),
      Row(
        children: [
          Expanded(
            child: Text(
              typeLabels[t['type']] ?? '내역',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          if (dialog)
            IconButton(
              onPressed: close,
              icon: const Icon(Icons.close),
              tooltip: '닫기',
            ),
        ],
      ),
      Text(
        money(t['amount'] as int),
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
      ),
      Text(t['date'] as String),
      if (e != null) ...[
        for (final p in rows(e['postings']))
          Text(
            '${accountName(p['account'] as String)}  ${money(p['delta'] as int)}',
          ),
        for (final a in app.store.allocations(t['id'] as String))
          Text(
            '${a['category_name']} / ${a['subcategory_name'] ?? '—'} · ${money(a['amount'] as int)}',
          ),
      ],
      if ((t['memo'] as String? ?? '').isNotEmpty) Text(t['memo'] as String),
      if (primary) ...[
        if (e['rule'] != null)
          const Text('정기 내역에서 생성되었습니다. 삭제하면 해당 회차는 다시 생성하지 않습니다.'),
        for (final s in rows(e['shares']))
          Text(
            '${s['person']} · 남은 정산 ${money(app.service.remainingShare(e, s))}',
          ),
        for (final r in rows(e['receipts']).where((r) => r['voided'] != true))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('정산 수령 ${money(r['amount'] as int)}'),
            subtitle: Text(r['date'] as String),
            trailing: TextButton(
              onPressed: () async {
                if (await confirm(
                  context,
                  '수령 취소',
                  '계좌 입금과 정산 수령 기록을 함께 취소합니다.',
                )) {
                  act(
                    () => app.service.voidChild(
                      'entry',
                      id,
                      'receipts',
                      r['id'] as String,
                    ),
                  );
                  close();
                }
              },
              child: const Text('취소'),
            ),
          ),
        for (final r in rows(e['refunds']).where((r) => r['voided'] != true))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('환불 ${money(r['amount'] as int)}'),
            trailing: TextButton(
              onPressed: () {
                act(
                  () => app.service.voidChild(
                    'entry',
                    id,
                    'refunds',
                    r['id'] as String,
                  ),
                );
                close();
              },
              child: const Text('환불 취소'),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (e['type'] != 'adjustment')
              OutlinedButton(
                onPressed: () {
                  close();
                  add(existing: e);
                },
                child: const Text('수정'),
              ),
            if (e['type'] != 'adjustment')
              OutlinedButton(
                onPressed: () {
                  close();
                  add(existing: e, copy: true);
                },
                child: const Text('복사'),
              ),
            if (e['type'] == 'expense' && rows(e['shares']).isEmpty)
              OutlinedButton(
                onPressed: () {
                  close();
                  cashAction(
                    '환불 기록',
                    (v) => app.service.refund(
                      id,
                      parseMoney(v['amount'] as String),
                      v['account'] as String,
                      v['date'] as String,
                    ),
                  );
                },
                child: const Text('환불'),
              ),
            TextButton(
              onPressed: () async {
                if (await confirm(
                  context,
                  '내역 삭제',
                  '연결된 정산 수령·환불도 함께 취소됩니다. 계좌 잔액과 집계가 다시 계산됩니다.',
                )) {
                  act(() => app.store.save('entry', {...e, 'deleted': true}));
                  close();
                }
              },
              child: const Text('삭제'),
            ),
          ],
        ),
      ],
      if (!primary && (e != null || debt != null))
        TextButton(
          onPressed: () {
            close();
            setState(() {
              tab = debt != null ? 5 : 6;
              if (debt == null) section = '정산';
            });
          },
          child: const Text('연결된 기록 관리'),
        ),
    ]);
  }

  Widget ledger(double width) {
    final entries = app.store.entries(
      period: month,
      account: accountFilter,
      search: search,
      collapseSettlements: true,
    );
    final selected = entries.where((t) => t['id'] == selectedEntry).firstOrNull;
    final list = Column(
      children: [
        monthPicker(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => showSettlement(context, app),
            icon: const Icon(Icons.link),
            label: const Text('여러 내역을 정산으로 묶기'),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: selectField(
                '계좌',
                accountFilter ?? '',
                [('', '전체 계좌'), ...accountOptions],
                (v) => setState(() {
                  accountFilter = v == '' ? null : v;
                  selectedEntry = null;
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: searchInput,
                decoration: const InputDecoration(
                  labelText: '메모·분류 검색',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() {
                  search = v;
                  selectedEntry = null;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: entries.isEmpty
              ? empty('기록이 없어요', '선택한 기간·계좌·검색어를 확인해 주세요.')
              : ListView.builder(
                  key: ValueKey('ledger/$listRevision'),
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: entries.length,
                  itemBuilder: (c, i) =>
                      Card(child: transactionTile(entries[i])),
                ),
        ),
      ],
    );
    return width < 1000
        ? list
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: list),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Card(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: selected == null
                        ? empty('내역 상세', '왼쪽 내역을 선택해 주세요.')
                        : entryDetail(selected),
                  ),
                ),
              ),
            ],
          );
  }

  Future<void> editAccount([Json? a]) async {
    final v = await prompt(
      context,
      a == null ? '계좌 추가' : '계좌 설정',
      [
        PromptField('name', '계좌 이름', initial: a?['name'] as String? ?? ''),
        PromptField(
          'kind',
          '종류',
          initial: a?['kind'] as String? ?? 'bank',
          options: const [
            ('bank', '입출금 계좌'),
            ('cash', '현금'),
            ('savings', '적금·저축'),
            ('card', '신용카드'),
          ],
        ),
        if (a == null)
          const PromptField(
            'opening',
            '시작 잔액 (카드 미결제액은 음수)',
            initial: '0',
            money: true,
            signed: true,
          ),
        PromptField(
          'liquid',
          '사용 가능 금액에 포함',
          initial: a?['liquid'] == false ? 'false' : 'true',
          options: const [('true', '포함'), ('false', '제외')],
        ),
      ],
      note:
          '적금은 전체 보유 금액에 포함됩니다. 카드 결제는 카드 계좌 지출, 카드 대금 납부는 통장 → 카드 이동으로 기록하세요.',
    );
    if (v != null) {
      act(
        () => app.service.saveAccount(
          id: a?['id'] as String?,
          name: v['name'] as String,
          kind: v['kind'] as String,
          opening: a == null
              ? parseMoney(v['opening'] as String, signed: true)
              : 0,
          liquid: v['liquid'] == 'true',
        ),
      );
    }
  }

  Widget accounts() => scroll([
    Row(
      children: [
        const Expanded(child: Text('계좌를 누르면 해당 계좌 내역으로 이동합니다.')),
        FilledButton.icon(
          onPressed: () => editAccount(),
          icon: const Icon(Icons.add),
          label: const Text('계좌'),
        ),
      ],
    ),
    for (final a in app.store.all('account'))
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(18),
          leading: Icon(
            a['kind'] == 'savings'
                ? Icons.savings_outlined
                : a['kind'] == 'card'
                ? Icons.credit_card
                : Icons.account_balance_outlined,
          ),
          title: Text(
            '${a['name']}${a['archived'] == true ? ' · 보관됨' : ''}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            '${{'bank': '입출금', 'cash': '현금', 'savings': '적금·저축', 'card': '신용카드'}[a['kind']]} · ${money(app.store.balance(a['id'] as String))}',
          ),
          onTap: () => setState(() {
            accountFilter = a['id'] as String;
            tab = 1;
            search = '';
            searchInput.clear();
            selectedEntry = null;
          }),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') {
                editAccount(a);
              } else if (v == 'adjust') {
                adjustBalance(a);
              } else {
                act(
                  () => app.store.save('account', {
                    ...a,
                    'archived': a['archived'] != true,
                  }),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('계좌 설정')),
              PopupMenuItem(value: 'adjust', child: Text('잔액 맞추기')),
              PopupMenuItem(value: 'archive', child: Text('보관 상태 전환')),
            ],
          ),
        ),
      ),
    if (app.store.all('account').isEmpty)
      empty('등록된 계좌가 없어요', '통장이나 현금 지갑부터 추가해 보세요.'),
  ]);
  Future<void> adjustBalance(Json a) async {
    final v = await prompt(context, '실제 잔액 맞추기', [
      PromptField(
        'amount',
        '실제 잔액',
        money: true,
        signed: true,
        initial: '${app.store.balance(a['id'] as String)}',
      ),
      const PromptField('memo', '조정 메모'),
    ], note: '차액은 잔액 조정으로 기록하며 수입·지출에서는 제외합니다.');
    if (v != null) {
      act(() {
        final delta =
            parseMoney(v['amount'] as String, signed: true) -
            app.store.balance(a['id'] as String);
        require(delta != 0, '이미 같은 잔액이에요.');
        app.store.save('entry', {
          'id': uuid.v4(),
          'date': today(),
          'type': 'adjustment',
          'amount': delta.abs(),
          'memo': v['memo'],
          'postings': [
            {'account': a['id'], 'delta': delta},
          ],
          'allocations': <Json>[],
          'shares': <Json>[],
          'receipts': <Json>[],
          'refunds': <Json>[],
        });
      });
    }
  }

  Widget report() {
    final data = breakdown(
      period,
      parent: categoryFilter.isEmpty ? null : categoryFilter,
    );
    return scroll([
      Row(
        children: [
          Expanded(child: monthPicker(year: annual)),
          Switch(value: annual, onChanged: (v) => setState(() => annual = v)),
          const Text('연간'),
        ],
      ),
      Row(
        children: [
          Expanded(child: metric('수입', app.store.flow(period, 'income'))),
          Expanded(child: metric('지출', app.store.flow(period, 'expense'))),
        ],
      ),
      panel(
        categoryFilter.isEmpty ? '대분류별 지출' : '$categoryFilter · 소분류별 지출',
        spaced([
          ExpenseChart(
            data,
            onSelect: categoryFilter.isEmpty
                ? (v) => setState(() => categoryFilter = v)
                : null,
          ),
          if (data.any((e) => e.$2 < 0))
            const Text('환불로 순지출이 음수인 분류는 원형 그래프에서 제외하며 아래 금액에는 반영합니다.'),
          for (final e in data.where((e) => e.$2 < 0))
            Text('${e.$1}: ${money(e.$2)}'),
        ]),
        trailing: categoryFilter.isNotEmpty
            ? TextButton(
                onPressed: () => setState(() => categoryFilter = ''),
                child: const Text('대분류로'),
              )
            : null,
      ),
      panel(
        '${month.substring(0, 4)}년 월별 흐름',
        MonthlyFlowChart([
          for (var m = 1; m <= 12; m++)
            (
              month: m,
              income: app.store.flow(
                '${month.substring(0, 4)}-${m.toString().padLeft(2, '0')}',
                'income',
              ),
              expense: app.store.flow(
                '${month.substring(0, 4)}-${m.toString().padLeft(2, '0')}',
                'expense',
              ),
            ),
        ]),
      ),
      BudgetPanel(app: app, month: month),
    ]);
  }

  Widget more() => switch (section) {
    '정산' => settlements(),
    '카테고리' => categories(),
    '설정' => settings(),
    '충돌 해결' => conflicts(),
    _ => scroll([
      for (final (label, icon, description) in [
        ('정산', Icons.group_outlined, '누구에게 얼마를 받았는지'),
        ('카테고리', Icons.category_outlined, '대분류·소분류 추가와 관리'),
        ('설정', Icons.settings_outlined, 'Google Drive · 백업 · 엑셀 · 화면'),
        ('충돌 해결', Icons.sync_problem_outlined, '다른 기기에서 함께 수정한 기록'),
      ])
        Card(
          child: ListTile(
            leading: Icon(icon),
            title: Text(label),
            subtitle: Text(description),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => section = label),
          ),
        ),
    ]),
  };
  Future<void> cashAction(
    String title,
    void Function(Json) save, {
    int? initial,
    bool optional = false,
  }) async {
    final v = await prompt(context, title, [
      PromptField(
        'amount',
        '금액',
        initial: initial == null ? '' : '$initial',
        money: true,
      ),
      PromptField('date', '날짜 (YYYY-MM-DD)', initial: today()),
      PromptField(
        'account',
        '계좌',
        initial: optional ? '' : accountOptions.firstOrNull?.$1 ?? '',
        options: [if (optional) ('', '계좌 입출금 없이 기록'), ...accountOptions],
      ),
    ]);
    if (v != null) act(() => save(v));
  }

  Widget settlements() {
    final entries = app.store
        .all('entry')
        .where((e) => rows(e['shares']).isNotEmpty)
        .toList();
    final total = sumMoney(
      entries.expand(
        (e) => rows(e['shares']).map((s) => app.service.remainingShare(e, s)),
      ),
    );
    final groups = app.store.all('settlement_group');
    return scroll([
      FilledButton.icon(
        onPressed: () => showSettlement(context, app),
        icon: const Icon(Icons.add),
        label: const Text('정산 묶음 만들기'),
      ),
      const Text('연결된 수입·지출의 차액을 자동 집계합니다. 받을 돈 체크는 계좌 잔액과 합계에 영향을 주지 않습니다.'),
      for (final g in groups)
        Builder(
          builder: (_) {
            final net = app.store.settlementTotals(g)['net'] as int;
            final unpaid = rows(
              g['claims'],
            ).where((c) => c['received'] != true && c['debt'] == null);
            return Card(
              child: ListTile(
                title: Text(
                  '${g['name']} · ${g['closed'] == true ? '마감' : '진행 중'}',
                ),
                subtitle: Text(
                  '${g['date']} · 연결 ${(g['members'] as List).length}건 · 받을 돈 체크 ${unpaid.length}건',
                ),
                trailing: Text(
                  '${net > 0
                      ? '순수입'
                      : net < 0
                      ? '순지출'
                      : '차액'} ${money(net.abs())}',
                ),
                onTap: () =>
                    showSettlement(context, app, id: g['id'] as String),
              ),
            );
          },
        ),
      if (entries.isNotEmpty) const Text('기존 방식의 정산 · 이전 기록 유지'),
      if (entries.isNotEmpty) metric('기존 정산에서 아직 받지 못한 금액', total),
      if (entries.isNotEmpty)
        const Text('기존 정산 수령은 계좌 잔액에만 반영하며 수입으로 집계하지 않습니다.'),
      for (final e in entries)
        panel(
          '${e['date']} · ${entryLabel(e)}',
          Column(
            children: [
              for (final s in rows(e['shares']))
                Builder(
                  builder: (c) {
                    final left = app.service.remainingShare(e, s);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s['person'] as String),
                      subtitle: Text(
                        '청구 ${money(s['amount'] as int)} · 받은 금액 ${money((s['amount'] as int) - left)}',
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: left <= 0
                                ? null
                                : () => cashAction(
                                    '${s['person']} 정산금 받기',
                                    (v) => app.service.receive(
                                      e['id'] as String,
                                      s['id'] as String,
                                      parseMoney(v['amount'] as String),
                                      v['account'] as String,
                                      v['date'] as String,
                                    ),
                                    initial: left,
                                  ),
                            child: Text(left == 0 ? '완료' : money(left)),
                          ),
                          if (left > 0)
                            IconButton(
                              tooltip: '남은 금액을 내 지출로 처리',
                              icon: const Icon(Icons.more_horiz),
                              onPressed: () async {
                                if (await confirm(
                                  context,
                                  '남은 정산금 처리',
                                  '남은 ${money(left)}을 본인의 지출로 전환합니다.',
                                )) {
                                  act(
                                    () => app.service.waive(
                                      e['id'] as String,
                                      s['id'] as String,
                                    ),
                                  );
                                }
                              },
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
          trailing: TextButton(
            onPressed: () {
              final t = app.store
                  .entries()
                  .where((t) => t['id'] == e['id'])
                  .firstOrNull;
              if (t != null) openEntry(t);
            },
            child: const Text('상세'),
          ),
        ),
      if (entries.isEmpty && groups.isEmpty)
        empty('정산 묶음이 없어요', '정산 묶음을 만들고 여러 수입·지출을 선택하세요.'),
    ]);
  }

  Widget debts() {
    final debts = app.store.all('debt');
    return scroll([
      Row(
        children: [
          Expanded(
            child: metric(
              '받을 돈 총액',
              sumMoney(
                debts
                    .where((d) => d['direction'] == 'lent')
                    .map(app.service.debtBalance),
              ),
            ),
          ),
          Expanded(
            child: metric(
              '갚을 돈 총액',
              sumMoney(
                debts
                    .where((d) => d['direction'] == 'borrowed')
                    .map(app.service.debtBalance),
              ),
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: () => add(type: 'debt'),
          icon: const Icon(Icons.add),
          label: const Text('빚 등록'),
        ),
      ),
      if (debts.isEmpty)
        empty('등록된 빚이 없어요', '빌린 돈이나 빌려준 돈을 등록하면 남은 금액을 모아 볼 수 있어요.'),
      for (final d in debts)
        panel(
          d['person'] as String,
          spaced([
            amountHighlight(
              app.service.debtBalance(d) == 0
                  ? '상환 완료'
                  : d['direction'] == 'lent'
                  ? '앞으로 받을 돈'
                  : '앞으로 갚을 돈',
              app.service.debtBalance(d),
              incoming: d['direction'] == 'lent',
            ),
            if (d['due'] != null) Text('상환 예정 ${d['due']}'),
            if ((d['memo'] as String).isNotEmpty) Text(d['memo'] as String),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: app.service.debtBalance(d) == 0
                      ? null
                      : () => cashAction(
                          d['direction'] == 'lent' ? '수령 기록' : '상환 기록',
                          (v) => app.service.debtEvent(
                            d['id'] as String,
                            parseMoney(v['amount'] as String),
                            v['date'] as String,
                            account: v['account'] == ''
                                ? null
                                : v['account'] as String,
                          ),
                          initial: app.service.debtBalance(d),
                          optional: true,
                        ),
                  child: Text(d['direction'] == 'lent' ? '수령 기록' : '상환 기록'),
                ),
                OutlinedButton(
                  onPressed: () => cashAction(
                    '원금 추가',
                    (v) => app.service.debtEvent(
                      d['id'] as String,
                      parseMoney(v['amount'] as String),
                      v['date'] as String,
                      type: 'add',
                      account: v['account'] == ''
                          ? null
                          : v['account'] as String,
                    ),
                    optional: true,
                  ),
                  child: const Text('원금 추가'),
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('원금·상환 기록'),
              subtitle: Text(
                '${rows(d['events']).where((e) => e['voided'] != true).length}건 · 펼쳐서 확인',
              ),
              children: [
                for (final e in rows(
                  d['events'],
                ).where((e) => e['voided'] != true))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${e['type'] == 'add' ? '원금' : '상환'} ${money(e['amount'] as int)}',
                    ),
                    subtitle: Text(
                      '${e['date']} · ${accountName(e['account'] as String?)}',
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        if (await confirm(
                          context,
                          '기록 취소',
                          '연결된 계좌 입출금도 함께 취소합니다.',
                        )) {
                          act(
                            () => app.service.voidChild(
                              'debt',
                              d['id'] as String,
                              'events',
                              e['id'] as String,
                            ),
                          );
                        }
                      },
                      child: const Text('취소'),
                    ),
                  ),
              ],
            ),
          ]),
        ),
    ]);
  }

  Widget amountHighlight(String label, int amount, {bool incoming = false}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: incoming
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              money(amount),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget recurringSummary(String month) {
    final totals = app.service.plannedFlow(month);
    return spaced([
      amountHighlight(
        '고정 수입 · 실제 + 남은 예상',
        totals['expected_regular_income']!,
        incoming: true,
      ),
      amountHighlight(
        '고정 지출 · 실제 + 남은 예상',
        totals['expected_regular_expense']!,
      ),
      summaryAmount('처리된 고정 지출', totals['actual_regular_expense']!),
      summaryAmount('앞으로의 고정 지출', totals['future_expense']!),
      summaryAmount(
        '고정 수입 − 고정 지출',
        totals['expected_regular_income']! -
            totals['expected_regular_expense']!,
      ),
      const Text(
        '지나간 회차는 실제 기록된 금액만 합산합니다. 이후 회차는 현재 정기 일정으로 계산합니다.',
        style: TextStyle(fontSize: 12),
      ),
    ]);
  }

  Widget rules() {
    final year = month.substring(0, 4);
    final period = recurringAnnual ? year : month;
    final totals = app.service.plannedFlow(year);
    final items = <Json>[
      for (final e in app.store.all('entry'))
        if (e['rule'] != null && (e['date'] as String).startsWith(period))
          {...e, 'actual': true},
    ];
    final known = app.store.events
        .where((e) => e['kind'] == 'entry' && e['data']['rule'] != null)
        .map(
          (e) =>
              '${e['data']['rule']}/${e['data']['scheduled_on'] ?? e['data']['date']}',
        )
        .toSet();
    final end = recurringAnnual
        ? '$year-12-31'
        : day(
            DateTime.utc(int.parse(year), int.parse(month.substring(5)) + 1, 0),
          );
    for (final rule in app.store.all('rule')) {
      if (app.store.conflicts.containsKey('rule/${rule['id']}')) continue;
      for (final (r, on) in app.service.dueDates(rule, end)) {
        if (on.startsWith(period) &&
            on.compareTo(today()) > 0 &&
            !known.contains('${rule['id']}/$on')) {
          items.add({...r, 'rule': rule['id'], 'date': on, 'actual': false});
        }
      }
    }
    final annualized = recurringAnnual && !recurringFromStart;
    if (annualized) {
      items.clear();
      for (final rule in app.store.all('rule')) {
        if (app.store.conflicts.containsKey('rule/${rule['id']}')) continue;
        final revisions =
            rows(rule['revisions'])
                .where(
                  (r) =>
                      (r['effective'] as String).compareTo('$year-12-31') <= 0,
                )
                .toList()
              ..sort(
                (a, b) => (a['effective'] as String).compareTo(
                  b['effective'] as String,
                ),
              );
        if (revisions.isEmpty) continue;
        final r = revisions.last;
        if (r['end'] != null &&
            (r['end'] as String).compareTo('$year-01-01') < 0) {
          continue;
        }
        final count = r['cycle'] == 'monthly' ? 12 : 1;
        for (var i = 0; i < count; i++) {
          items.add({
            ...r,
            'rule': rule['id'],
            'date': '$year-${(i + 1).toString().padLeft(2, '0')}-01',
            'actual': false,
          });
        }
      }
      for (final type in ['income', 'expense']) {
        totals['expected_regular_$type'] = items
            .where((item) => item['type'] == type)
            .fold<int>(0, (sum, item) => sum + (item['amount'] as int));
      }
    }
    items.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    final annualGroups = <String, List<Json>>{};
    for (final item in items) {
      annualGroups.putIfAbsent(item['rule'] as String, () => []).add(item);
    }
    return Column(
      children: [
        monthPicker(year: true),
        panel(
          '$year년 전체',
          spaced([
            summaryAmount('고정 수입', totals['expected_regular_income']!),
            summaryAmount('고정 지출', totals['expected_regular_expense']!),
            summaryAmount(
              '고정 수입 − 고정 지출',
              totals['expected_regular_income']! -
                  totals['expected_regular_expense']!,
            ),
            Text(
              annualized
                  ? '12개월 환산 · 해당 연도 마지막 설정 금액 기준 (실제 내역과 별도)'
                  : '지난 회차는 실제 기록 · 앞으로의 회차는 예상',
              style: const TextStyle(fontSize: 12),
            ),
          ]),
          trailing: TextButton.icon(
            onPressed: () => add(recurring: true),
            icon: const Icon(Icons.add),
            label: const Text('정기 등록'),
          ),
        ),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('월별 내역')),
            ButtonSegment(value: true, label: Text('연간 내역')),
          ],
          selected: {recurringAnnual},
          onSelectionChanged: (values) =>
              setState(() => recurringAnnual = values.single),
        ),
        if (!recurringAnnual) monthPicker(),
        Expanded(
          child: ListView(
            key: ValueKey(
              recurringAnnual
                  ? 'recurring-year/$year'
                  : 'recurring-month/$month',
            ),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (recurringAnnual)
                SwitchListTile(
                  title: const Text('시작일부터 계산'),
                  subtitle: Text(
                    recurringFromStart
                        ? '시작·종료일을 반영한 실제 금액과 남은 예상 금액'
                        : '월 정기금액 × 12개월 · 연 정기금액 × 1회',
                  ),
                  value: recurringFromStart,
                  onChanged: (value) =>
                      setState(() => recurringFromStart = value),
                ),
              if (!recurringAnnual)
                panel('$month 월간 합계', recurringSummary(month)),
              if (items.isEmpty)
                empty('이 기간의 정기 내역이 없어요', '과거 실제 기록 또는 앞으로 예정된 회차가 이곳에 표시됩니다.'),
              if (recurringAnnual)
                for (final group in annualGroups.entries)
                  annualRecurringCard(group.key, group.value),
              if (!recurringAnnual)
                for (final item in items)
                  Card(
                    child: ListTile(
                      key: ValueKey(
                        'recurring-item/${item['id']}/${item['date']}',
                      ),
                      leading: Icon(
                        item['actual'] == true
                            ? Icons.check_circle_outline
                            : Icons.schedule,
                      ),
                      title: Text(
                        (item['memo'] as String? ?? '').trim().isNotEmpty
                            ? item['memo'] as String
                            : '정기 ${typeLabels[item['type']]}',
                      ),
                      subtitle: Text(
                        '${item['date']} · ${item['actual'] == true ? '실제' : '예상'} · ${typeLabels[item['type']]}',
                      ),
                      trailing: Text(
                        money(item['amount'] as int),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onTap: item['actual'] != true
                          ? null
                          : () {
                              final entry = app.store
                                  .entries()
                                  .where((e) => e['id'] == item['id'])
                                  .firstOrNull;
                              if (entry != null) openEntry(entry);
                            },
                    ),
                  ),
              ExpansionTile(
                title: const Text('등록된 정기 일정 관리'),
                subtitle: const Text('전체 일정 · 수정 · 일시 정지 · 종료'),
                children: [ruleCards()],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget annualRecurringCard(String ruleId, List<Json> items) {
    final latest = items.last;
    final memo = (latest['memo'] as String? ?? '').trim();
    var actual = 0;
    var expected = 0;
    var actualCount = 0;
    for (final item in items) {
      if (item['actual'] == true) {
        actual += item['amount'] as int;
        actualCount++;
      } else {
        expected += item['amount'] as int;
      }
    }
    return Card(
      key: ValueKey('recurring-annual-item/$ruleId'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  memo.isEmpty ? '정기 ${typeLabels[latest['type']]}' : memo,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  money(actual + expected),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (!recurringFromStart)
              Text(
                '${typeLabels[latest['type']]} · ${money(latest['amount'] as int)} × ${items.length}회 · 연간 환산',
              )
            else ...[
              Text(
                '${typeLabels[latest['type']]} · ${items.first['date']} ~ ${latest['date']} · ${items.length}회',
              ),
              Text(
                '실제 $actualCount회 ${money(actual)} + 예상 ${items.length - actualCount}회 ${money(expected)}',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget ruleCards() => Column(
    children: [
      for (final rule in app.store.all('rule'))
        Builder(
          builder: (c) {
            final r = rows(rule['revisions']).last;
            final next = app.service.nextOccurrence(rule);
            final memo = (r['memo'] as String? ?? '').trim();
            return panel(
              memo.isNotEmpty ? memo : '${r['category_name'] ?? '정기 이동'}',
              spaced([
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Chip(label: Text('정기 ${typeLabels[r['type']]}')),
                    Chip(
                      label: Text(
                        rule['paused'] == true
                            ? '일시 정지'
                            : next != null
                            ? '진행 중'
                            : '다음 예정 없음',
                      ),
                    ),
                  ],
                ),
                amountHighlight(
                  r['cycle'] == 'monthly'
                      ? '매월 ${r['anchor_day']}일'
                      : '매년 ${r['anchor_month']}월 ${r['anchor_day']}일',
                  r['amount'] as int,
                  incoming: r['type'] == 'income',
                ),
                if (next != null)
                  Text(
                    '다음 예정  ${next.$2}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  '${accountName(r['account'] as String)}${r['type'] == 'transfer' ? ' → ${accountName(r['destination'] as String)}' : ''}',
                ),
                Text(
                  [
                    r['category_name'],
                    r['subcategory_name'],
                  ].whereType<String>().where((s) => s.isNotEmpty).join(' › '),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('일정 관리'),
                  subtitle: Text('적용 ${r['effective']}부터'),
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        if (next != null)
                          TextButton(
                            onPressed: () async {
                              if (await confirm(
                                context,
                                '회차 건너뛰기',
                                '${next.$2}의 자동 기록을 건너뜁니다.',
                              )) {
                                act(
                                  () =>
                                      app.service.skipOccurrence(rule, next.$2),
                                );
                              }
                            },
                            child: const Text('다음 회차 건너뛰기'),
                          ),
                        OutlinedButton(
                          onPressed: () => act(
                            () => app.service.toggleRule(rule['id'] as String),
                          ),
                          child: Text(rule['paused'] == true ? '재개' : '일시 정지'),
                        ),
                        TextButton(
                          onPressed: () => add(
                            recurring: true,
                            existing: r,
                            ruleId: rule['id'] as String,
                          ),
                          child: const Text('다음 적용일로 변경'),
                        ),
                        TextButton(
                          onPressed: () async {
                            if (await confirm(
                              context,
                              '정기 내역 종료',
                              '이미 생성된 거래는 유지하고 앞으로의 자동 기록을 중단합니다.',
                            )) {
                              act(
                                () => app.store.save('rule', {
                                  ...rule,
                                  'deleted': true,
                                }),
                              );
                            }
                          },
                          child: const Text('종료'),
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
            );
          },
        ),
    ],
  );
  Widget categories() => scroll([
    const Text('분류 이름을 바꾸거나 삭제해도 과거 거래의 분류명은 보존됩니다.'),
    for (final type in ['expense', 'income', 'transfer', 'settlement'])
      panel(
        '${typeLabels[type]} 카테고리',
        Column(
          children: [
            for (final parent
                in app.store
                    .all('category')
                    .where((c) => c['type'] == type && c['parent'] == null))
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(parent['name'] as String),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) => v == 'add'
                      ? editCategory(type, parent: parent['id'] as String)
                      : v == 'edit'
                      ? editCategory(type, existing: parent)
                      : deleteCategory(parent),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'add', child: Text('소분류 추가')),
                    PopupMenuItem(value: 'edit', child: Text('이름 변경')),
                    PopupMenuItem(value: 'delete', child: Text('삭제')),
                  ],
                ),
                children: [
                  for (final child
                      in app.store
                          .all('category')
                          .where((c) => c['parent'] == parent['id']))
                    ListTile(
                      title: Text(child['name'] as String),
                      onTap: () => editCategory(
                        type,
                        existing: child,
                        parent: parent['id'] as String,
                      ),
                      trailing: IconButton(
                        tooltip: '소분류 삭제',
                        onPressed: () => deleteCategory(child),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              ),
          ],
        ),
        trailing: TextButton.icon(
          onPressed: () => editCategory(type),
          icon: const Icon(Icons.add),
          label: const Text('대분류'),
        ),
      ),
  ]);
  Future<void> editCategory(
    String type, {
    String? parent,
    Json? existing,
  }) async {
    final v = await prompt(
      context,
      existing == null ? '${parent == null ? '대' : '소'}분류 추가' : '분류 이름 변경',
      [PromptField('name', '이름', initial: existing?['name'] as String? ?? '')],
    );
    if (v != null) {
      act(
        () => app.service.saveCategory(
          type,
          v['name'] as String,
          parent: parent,
          id: existing?['id'] as String?,
        ),
      );
    }
  }

  Future<void> deleteCategory(Json category) async {
    if (await confirm(
      context,
      '분류 삭제',
      '${category['name']} 및 하위 분류를 입력 목록에서 제거합니다. 과거 기록은 유지됩니다.',
    )) {
      act(() => app.service.deleteCategory(category['id'] as String));
    }
  }

  Widget settings() => scroll([
    panel(
      'Codex 파일 연결',
      spaced([
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('로컬 파일로 내역 수정 허용'),
          subtitle: const Text('켜 두면 Codex의 수정 요청을 자동으로 반영합니다. 앱을 열어 두세요.'),
          value: app.fileConnection.enabled,
          onChanged: (value) =>
              guarded(context, () => app.setFileConnection(value)),
        ),
        SelectableText('연결 폴더: ${device.deviceInfo()['folder']}/codex'),
        const Text(
          '수정 전에 자동 백업하며, 다른 곳에서 먼저 바뀐 내역은 덮어쓰지 않습니다. 연결 폴더에 쓸 수 있는 프로그램은 내역을 수정할 수 있습니다.',
        ),
        if (app.fileConnection.error != null)
          Text('파일 연결 오류: ${app.fileConnection.error}'),
        if (app.fileConnection.enabled)
          OutlinedButton(
            onPressed: () => guarded(context, app.pollFileConnection),
            child: const Text('지금 연결 확인'),
          ),
      ]),
    ),
    panel(
      '기기 저장과 웹 앱',
      spaced([
        Text('저장 폴더: ${device.deviceInfo()['folder']}'),
        Text(app.storageStatus),
        if (device.deviceInfo()['notice'] != '')
          Text(device.deviceInfo()['notice'] as String),
        const Text('입력은 이 기기에 저장됩니다. 동기화는 앱을 새로 열 때와 버튼을 누를 때만 실행합니다.'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => guarded(context, () async {
                final result = await device.install();
                if (mounted) message(context, result);
              }),
              child: const Text('앱 설치'),
            ),
            OutlinedButton(
              onPressed: checkWebUpdate,
              child: const Text('업데이트 확인'),
            ),
            TextButton(
              onPressed: () => guarded(context, () async {
                require(!app.syncing, '동기화가 끝난 뒤 삭제해 주세요.');
                if (!await confirm(
                  context,
                  '이 기기의 데이터 삭제',
                  '미전송 변경 ${app.store.unsent}건을 포함하여 이 폴더의 가계부와 자동 백업을 삭제합니다. Google Drive와 직접 내보낸 파일은 유지됩니다. 앱 제거만으로는 이 폴더가 삭제되지 않습니다. 계속할까요?',
                )) {
                  return;
                }
                await app.eraseDevice();
              }),
              child: const Text('이 기기의 데이터 삭제'),
            ),
          ],
        ),
        const Text('파일은 암호화되지 않습니다. 기기 잠금으로 보호해 주세요. 앱 제거 전 위 삭제 기능을 사용하세요.'),
      ]),
    ),
    panel(
      'Google Drive 동기화',
      spaced([
        const Text(
          '내 Google 계정으로 로그인하고 폴더를 선택합니다. 폴더 탐색을 위해 Google에서 Drive 전체 파일 접근 권한을 요청합니다. 실제 가계부 동기화는 선택 폴더만 사용합니다. 토큰 만료 시 동기화 버튼으로 다시 연결해 주세요.',
        ),
        Text(
          app.connected
              ? '${app.store.local('drive_email')}'
              : '이 기기에 안전하게 저장 중',
        ),
        Text(
          app.store.local('last_sync') == null
              ? '아직 동기화하지 않았어요.'
              : '마지막 완료 ${DateTime.parse(app.store.local('last_sync')!).toLocal()}',
        ),
        if (app.connected)
          Text('동기화 폴더: ${app.store.local('drive_folder_name')}'),
        Text('보낼 변경 ${app.store.unsent}건 · 선택한 내 Drive 폴더에 JSON으로 저장합니다.'),
        const Text('다른 기기에서도 같은 Google 계정과 같은 폴더를 선택해 주세요.'),
        if (!app.connected && app.store.local('drive_owner') != null)
          const Text(
            '이전 앱 전용 폴더 연결입니다. 다시 로그인해 일반 폴더를 선택하면 이 기기의 기록을 옮길 수 있어요.',
          ),
        if (!app.auth.configured)
          const Text('Google 로그인이 준비되지 않은 빌드입니다. 로그인을 지원하는 배포 버전을 설치해 주세요.'),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: app.syncing || driveConnecting
                  ? null
                  : () => app.connected
                        ? app.sync(interactive: true)
                        : connectDrive(),
              child: Text(
                driveConnecting
                    ? '연결 중…'
                    : app.connected
                    ? '지금 동기화'
                    : 'Google 로그인 · 폴더 선택',
              ),
            ),
            if (app.connected)
              TextButton(
                onPressed: app.syncing || driveConnecting
                    ? null
                    : () => guarded(context, () async {
                        if (await confirm(
                          context,
                          'Drive 연결 해제',
                          '이 기기와 Drive의 기존 기록은 유지됩니다. 다시 연결할 때 다른 계정이나 폴더를 선택할 수 있어요.',
                        )) {
                          await app.disconnect();
                        }
                      }),
                child: const Text('연결 해제 / 변경'),
              ),
          ],
        ),
      ]),
    ),
    panel(
      '엑셀과 백업',
      spaced([
        const Text(
          '엑셀은 일반 거래 편집·가져오기에 사용합니다. 정산·빚·설정까지 복원하려면 JSON 전체 백업을 사용하세요.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => export('xlsx'),
              child: const Text('엑셀 내보내기'),
            ),
            OutlinedButton(
              onPressed: () => export('csv'),
              child: const Text('CSV 내보내기'),
            ),
            OutlinedButton(
              onPressed: importFile,
              child: const Text('엑셀·CSV 가져오기'),
            ),
            OutlinedButton(
              onPressed: () => export('json'),
              child: const Text('전체 백업'),
            ),
            TextButton(onPressed: restoreFile, child: const Text('백업 복원')),
          ],
        ),
      ]),
    ),
    panel(
      '화면과 보안',
      spaced([
        selectField('테마', app.theme, const [
          ('system', '기기 설정'),
          ('light', '라이트'),
          ('dark', '다크'),
        ], (v) => act(() => app.preferences(v!))),
        const Text('웹 버전은 기기의 화면 잠금으로 보호해 주세요.'),
      ]),
    ),
    Text('차곡 웹 · KRW · Asia/Seoul\nGoogle Drive 연결 없이 모든 가계부 기능을 사용할 수 있습니다.'),
  ]);
  Future<void> checkWebUpdate() => guarded(context, () async {
    require(!app.syncing, '동기화가 끝난 뒤 업데이트해 주세요.');
    await app.flush();
    final available = await device.checkUpdate();
    if (!mounted) return;
    if (!available) {
      message(context, '현재 설치된 웹 앱이 최신 버전입니다.');
      return;
    }
    if (!await confirm(
      context,
      '웹 앱 업데이트',
      '기기에 저장한 뒤 새 버전으로 다시 엽니다. 현재 작성 중인 내용은 저장하거나 닫은 뒤 적용해 주세요.',
    )) {
      return;
    }
    require(!app.syncing, '동기화가 끝난 뒤 업데이트해 주세요.');
    await app.flush();
    await device.applyUpdate();
  });

  Future<void> connectDrive() async {
    setState(() => driveConnecting = true);
    await guarded(context, () async {
      require(!app.connected && !app.syncing, '기존 Drive 연결을 먼저 해제해 주세요.');
      await app.auth.token(interactive: true, refresh: true);
      final user = await app.drive.identity();
      if (!mounted) return;
      final folder = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DriveFolderPicker(
          drive: app.drive,
          email: user['emailAddress'] as String? ?? 'Google 계정',
        ),
      );
      if (folder == null || !mounted) return;
      final selected = DriveTransport(
        app.auth,
        folderId: () => folder['id'] as String,
      );
      try {
        final ledgers = await selected.ledgers();
        if (!mounted) return;
        String? chosen = app.store.ledgerId;
        if (ledgers.isNotEmpty) {
          chosen = await showDialog<String>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('연결할 가계부'),
              children: [
                for (final l in ledgers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, l['ledger']),
                    child: Text('${l['name']} · ${l['ledger']}'),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, 'new'),
                  child: const Text('이 기기의 가계부를 새로 연결'),
                ),
              ],
            ),
          );
          if (chosen == null) return;
        }
        if (!mounted) return;
        final opening = chosen != 'new' && chosen != app.store.ledgerId;
        if (!await confirm(
          context,
          '동기화 연결 확인',
          '${user['emailAddress']}\n폴더: ${folder['name']}\n\n${opening ? '현재 가계부를 자동 백업한 후 Drive의 가계부로 전환합니다. 두 가계부를 합치지는 않습니다.' : '이 기기의 가계부 기록을 이 계정과 폴더에 동기화합니다.'}',
        )) {
          return;
        }
        final currentUser = await selected.identity();
        require(
          currentUser['permissionId'] == user['permissionId'],
          'Google 계정이 변경되었어요. 다시 연결해 주세요.',
        );
        await selected.folder(folder['id'] as String);
        if (opening) {
          final changes = await selected.read(chosen);
          await app.restore({
            'format': 'chagok-backup',
            'version': 1,
            'ledger': chosen,
            'changes': changes,
          }, asNew: false);
        }
        if (!ledgers.any((l) => l['ledger'] == app.store.ledgerId)) {
          await selected.createLedger(app.store.ledgerId);
        }
        await app.bind(user, folder);
      } finally {
        selected.close();
      }
    });
    if (mounted) setState(() => driveConnecting = false);
  }

  Future<void> export(String extension) => guarded(context, () async {
    final interchange = Interchange(app.service);
    final bytes = extension == 'xlsx'
        ? interchange.excelBytes()
        : extension == 'csv'
        ? interchange.csvBytes()
        : Uint8List.fromList(utf8.encode(jsonEncode(app.store.exportBackup())));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '가계부 내보내기',
      fileName: 'chagok-${today()}.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: bytes,
    );
    if (path != null && mounted) message(context, '파일을 저장했어요.');
  });
  Future<PlatformFile?> pickFile(List<String> extensions) async =>
      (await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        withData: true,
      ))?.files.single;
  Future<Uint8List> fileBytes(PlatformFile file) async {
    require(file.size <= 20 * 1024 * 1024, '20MB 이하 파일을 선택해 주세요.');
    require(file.bytes != null, '파일을 읽지 못했어요. 다시 선택해 주세요.');
    return file.bytes!;
  }

  Future<void> restoreFile() => guarded(context, () async {
    final file = await pickFile(['json']);
    if (file == null) return;
    final backup = jsonDecode(utf8.decode(await fileBytes(file))) as Json;
    if (!mounted) return;
    if (await confirm(
      context,
      '전체 백업 복원',
      '현재 가계부를 자동 백업하고 새 가계부로 복원합니다. Drive 연결은 해제됩니다.',
    )) {
      await app.restore(backup);
      if (mounted) message(context, '복원했어요. 기존 가계부는 앱 데이터 폴더의 backups에 보관했어요.');
    }
  });
  Future<void> importFile() => guarded(context, () async {
    final file = await pickFile(['xlsx', 'csv']);
    if (file == null) return;
    final interchange = Interchange(app.service);
    final preview = interchange.preview(
      await fileBytes(file),
      file.extension ?? '',
    );
    if (!mounted) return;
    final selected = <int>{
      for (var i = 0; i < preview.length; i++)
        if (preview[i].error == null &&
            !preview[i].duplicate &&
            preview[i].action != '변경 없음')
          i,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text('가져오기 미리보기 · ${selected.length}건 선택'),
          content: SizedBox(
            width: 800,
            height: 450,
            child: ListView(
              children: [
                const Text(
                  '중복 의심 내역과 변경 없는 내역은 기본 제외합니다. 정산과 연결 거래는 함께 선택해야 합니다. 오류 행은 원본을 수정해 주세요.',
                ),
                for (var i = 0; i < preview.length; i++)
                  CheckboxListTile(
                    value: selected.contains(i),
                    onChanged:
                        preview[i].error != null || preview[i].action == '변경 없음'
                        ? null
                        : (v) => update(() {
                            if (v == true) {
                              selected.add(i);
                            } else {
                              selected.remove(i);
                            }
                          }),
                    title: Text(
                      '${preview[i].kind == 'settlement_group' ? '정산 묶음' : '내역'} ${preview[i].number}행 · ${preview[i].error ?? '${preview[i].action}${preview[i].duplicate ? ' · 중복 의심' : ''}'}',
                    ),
                    subtitle: preview[i].entry == null
                        ? null
                        : Text(
                            preview[i].kind == 'settlement_group'
                                ? '${preview[i].entry!['name']} · 연결 ${(preview[i].entry!['members'] as List).length}건 · 합계 자동 계산'
                                : '${preview[i].entry!['date']} · ${money(preview[i].entry!['amount'] as int)} · ${entryLabel(preview[i].entry!)}',
                          ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: selected.isEmpty ? null : () => Navigator.pop(c, true),
              child: const Text('선택한 내역 반영'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      interchange.apply(selected.map((i) => preview[i]).toList());
      app.changed();
      if (mounted) message(context, '${selected.length}건을 반영했어요.');
    }
  });
  Widget conflicts() => scroll([
    const Text(
      '같은 기록을 여러 기기에서 수정한 경우입니다. 공통된 이전 기록을 유지하며, 아래에서 사용할 버전을 선택하면 모든 기기에 반영됩니다.',
    ),
    for (final conflict in app.store.conflicts.entries)
      panel(
        '${conflict.key.split('/').first} · ${conflict.key.split('/').last.substring(0, 8)}',
        Column(
          children: [
            for (final event in conflict.value)
              ListTile(
                title: Text(
                  '${event['created_at']} · ${(event['device'] as String).substring(0, 8)}',
                ),
                subtitle: Text(
                  const JsonEncoder.withIndent('  ').convert(event['data']),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    if (await confirm(
                      context,
                      '이 버전 사용',
                      '다른 수정본을 대신해 선택한 내용으로 충돌을 해결합니다.',
                    )) {
                      act(
                        () => app.store.resolve(
                          conflict.key,
                          Map<String, dynamic>.from(event['data'] as Map),
                        ),
                      );
                    }
                  },
                  child: const Text('선택'),
                ),
              ),
          ],
        ),
      ),
    if (app.store.pending.isNotEmpty)
      panel(
        '연결된 기록을 기다리는 중',
        spaced([
          const Text(
            '연결된 계좌·정기 규칙·정산 기록이 누락되었거나 정산 연결이 중복됐습니다. 동기화 후에도 남으면 정산에서 연결 내역을 확인해 주세요.',
          ),
          if (app.store.pending.any((p) => p.startsWith('settlement_group/')))
            TextButton(
              onPressed: () => setState(() => section = '정산'),
              child: const Text('정산 연결 확인'),
            ),
          FilledButton(
            onPressed: () => app.sync(interactive: true),
            child: const Text('다시 동기화'),
          ),
        ]),
      ),
    if (app.store.conflicts.isEmpty && app.store.pending.isEmpty)
      empty('해결할 충돌이 없어요', '기기별 변경 사항이 일치합니다.'),
  ]);
}
