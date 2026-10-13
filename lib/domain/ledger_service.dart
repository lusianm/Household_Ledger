import '../data/ledger_store.dart';
import 'value.dart';

class LedgerService {
  final LedgerStore store;
  LedgerService(this.store);
  void checkAccount(String id) =>
      require(store.get('account', id) != null, '계좌를 먼저 등록해 주세요.');
  void checkDate(String value) {
    date(value);
    require(value.compareTo(today()) <= 0, '미래 내역은 정기 내역으로 등록해 주세요.');
  }

  void seedCategories() {
    if (store.events.any((e) => e['kind'] == 'category')) return;
    final changes = <(String, Json)>[];
    for (final group in defaults.entries) {
      for (final parent in group.value.entries) {
        final id = stableId('${store.ledgerId}/${group.key}/${parent.key}');
        changes.add((
          'category',
          {'id': id, 'type': group.key, 'name': parent.key, 'parent': null},
        ));
        for (final name in parent.value) {
          changes.add((
            'category',
            {
              'id': stableId('$id/$name'),
              'type': group.key,
              'name': name,
              'parent': id,
            },
          ));
        }
      }
    }
    store.saveBatch(changes);
  }

  String saveAccount({
    String? id,
    required String name,
    String kind = 'bank',
    int opening = 0,
    bool liquid = true,
    String? opened,
  }) {
    final key = id ?? uuid.v4();
    final old = store.get('account', key);
    require(
      !store
          .all('account')
          .any((a) => a['id'] != key && a['name'] == name.trim()),
      '같은 이름의 계좌가 있어요. 구분할 수 있는 이름을 입력해 주세요.',
    );
    store.save('account', {
      ...?old,
      'id': key,
      'name': name.trim(),
      'kind': kind,
      'liquid': kind != 'card' && liquid,
      'opening': old?['opening'] ?? opening,
      'date': old?['date'] ?? opened ?? today(),
    });
    return key;
  }

  void saveCategory(String type, String name, {String? parent, String? id}) {
    final label = name.trim();
    require(label.isNotEmpty && label.length <= 60, '분류 이름은 1~60자로 입력해 주세요.');
    if (parent != null) {
      final p = store.get('category', parent);
      require(
        p != null &&
            p['deleted'] != true &&
            p['parent'] == null &&
            p['type'] == type,
        '대분류를 선택해 주세요.',
      );
    }
    require(
      !store
          .all('category')
          .any(
            (c) =>
                c['type'] == type &&
                c['parent'] == parent &&
                c['name'] == label &&
                c['id'] != id,
          ),
      '같은 이름의 분류가 있어요.',
    );
    store.save('category', {
      'id': id ?? uuid.v4(),
      'name': label,
      'type': type,
      'parent': parent,
    });
  }

  void deleteCategory(String id) {
    final targets = store
        .all('category')
        .where((c) => c['id'] == id || c['parent'] == id);
    store.saveBatch(
      targets.map((c) => ('category', {...c, 'deleted': true})).toList(),
    );
  }

  Json allocation(
    int amount,
    String category, {
    String? subcategory,
    String? categoryId,
    String? subcategoryId,
  }) => {
    'amount': amount,
    'category_name': category,
    'subcategory_name': subcategory?.isEmpty == true ? null : subcategory,
    'category_id': categoryId,
    'subcategory_id': subcategoryId,
  };
  Json makeEntry({
    String? id,
    required String type,
    required int amount,
    required String account,
    String? destination,
    required String on,
    String memo = '',
    List<Json> allocations = const [],
    List<Json> shares = const [],
  }) {
    checkAccount(account);
    checkDate(on);
    if (type == 'transfer') {
      require(
        destination != null && destination != account,
        '서로 다른 출발·도착 계좌를 선택해 주세요.',
      );
      checkAccount(destination!);
    }
    return {
      'id': id ?? uuid.v4(),
      'date': on,
      'type': type,
      'amount': amount,
      'memo': memo,
      'postings': [
        {'account': account, 'delta': type == 'income' ? amount : -amount},
        if (type == 'transfer') {'account': destination, 'delta': amount},
      ],
      'allocations': allocations,
      'shares': shares,
      'receipts': <Json>[],
      'refunds': <Json>[],
    };
  }

  void saveEntry(Json entry) {
    checkDate(entry['date'] as String);
    for (final p in rows(entry['postings'])) {
      checkAccount(p['account'] as String);
    }
    store.save('entry', entry);
  }

  int remainingShare(Json entry, Json share) =>
      (share['amount'] as int) -
      sumMoney(
        rows(entry['receipts'])
            .where((r) => r['voided'] != true && r['share'] == share['id'])
            .map((r) => r['amount'] as int),
      );
  void receive(
    String entryId,
    String shareId,
    int amount,
    String account,
    String on,
  ) {
    checkAccount(account);
    checkDate(on);
    final entry = store.get('entry', entryId)!;
    require(entry['deleted'] != true, '삭제된 정산입니다.');
    entry['receipts'] = [
      ...rows(entry['receipts']),
      {
        'id': uuid.v4(),
        'share': shareId,
        'amount': amount,
        'account': account,
        'date': on,
      },
    ];
    store.save('entry', entry);
  }

  void waive(String entryId, String shareId) {
    final e = store.get('entry', entryId)!;
    final shares = rows(e['shares']);
    final share = shares.firstWhere((s) => s['id'] == shareId);
    final left = remainingShare(e, share);
    require(left > 0, '남은 정산금이 없어요.');
    final allocations = rows(e['allocations']);
    require(allocations.isNotEmpty, '본인 부담 분류를 먼저 지정해 주세요.');
    allocations.first['amount'] = (allocations.first['amount'] as int) + left;
    share['amount'] = (share['amount'] as int) - left;
    e['shares'] = shares.where((s) => s['amount'] > 0).toList();
    e['allocations'] = allocations;
    store.save('entry', e);
  }

  void voidChild(String kind, String ownerId, String field, String childId) {
    final parent = store.get(kind, ownerId)!;
    final list = rows(parent[field]);
    list.firstWhere((e) => e['id'] == childId)['voided'] = true;
    parent[field] = list;
    store.save(kind, parent);
  }

  void refund(String id, int amount, String account, String on) {
    positiveMoney(amount);
    checkAccount(account);
    checkDate(on);
    final e = store.get('entry', id)!;
    require(
      e['type'] == 'expense' && rows(e['shares']).isEmpty,
      '공동 결제는 정산을 정리한 뒤 환불을 기록해 주세요.',
    );
    final source = rows(e['allocations']);
    final prior = rows(e['refunds']).where((r) => r['voided'] != true);
    final remaining = [
      for (var i = 0; i < source.length; i++)
        (source[i]['amount'] as int) +
            sumMoney(
              prior.map((r) => rows(r['allocations'])[i]['amount'] as int),
            ),
    ];
    final total = sumMoney(remaining);
    require(amount <= total, '남은 환불 가능액을 초과해요.');
    final amounts = remaining.map((n) => n * amount ~/ total).toList();
    var remainder = amount - sumMoney(amounts);
    for (var i = 0; i < amounts.length && remainder > 0; i++) {
      if (amounts[i] < remaining[i]) {
        amounts[i]++;
        remainder--;
      }
    }
    e['refunds'] = [
      ...rows(e['refunds']),
      {
        'id': uuid.v4(),
        'amount': amount,
        'account': account,
        'date': on,
        'allocations': [
          for (var i = 0; i < source.length; i++)
            {...source[i], 'amount': -amounts[i]},
        ],
      },
    ];
    store.save('entry', e);
  }

  String createDebt({
    required String person,
    required String direction,
    required int amount,
    required String on,
    String? account,
    String? due,
    String memo = '',
  }) {
    checkDate(on);
    if (account != null) checkAccount(account);
    final id = uuid.v4();
    store.save('debt', {
      'id': id,
      'person': person.trim(),
      'direction': direction,
      'date': on,
      'due': due,
      'memo': memo,
      'events': [
        {
          'id': uuid.v4(),
          'type': 'add',
          'amount': amount,
          'date': on,
          'account': account,
        },
      ],
    });
    return id;
  }

  int debtBalance(Json debt) => sumMoney(
    rows(debt['events'])
        .where((e) => e['voided'] != true)
        .map((e) => (e['amount'] as int) * (e['type'] == 'repay' ? -1 : 1)),
  );
  void debtEvent(
    String id,
    int amount,
    String on, {
    String type = 'repay',
    String? account,
  }) {
    checkDate(on);
    if (account != null) checkAccount(account);
    final d = store.get('debt', id)!;
    d['events'] = [
      ...rows(d['events']),
      {
        'id': uuid.v4(),
        'type': type,
        'amount': amount,
        'date': on,
        'account': account,
      },
    ];
    store.save('debt', d);
  }

  String saveRule(Json revision, {String? ruleId}) {
    checkAccount(revision['account'] as String);
    if (revision['type'] == 'transfer') {
      checkAccount(revision['destination'] as String);
    }
    final id = ruleId ?? uuid.v4();
    final rule =
        store.get('rule', id) ??
        {'id': id, 'paused': false, 'pauses': <Json>[], 'revisions': <Json>[]};
    revision = {...revision, 'id': uuid.v4()};
    final revisions = rows(rule['revisions']);
    require(
      revisions.isEmpty ||
          (revision['effective'] as String).compareTo(
                revisions.last['effective'] as String,
              ) >
              0,
      '새 규칙은 이전 적용일보다 뒤에서 시작해야 해요.',
    );
    rule['revisions'] = [...revisions, revision];
    store.save('rule', rule);
    return id;
  }

  void toggleRule(String id) {
    final r = store.get('rule', id)!;
    if (r['paused'] == true) {
      r['pauses'] = [
        ...rows(r['pauses']),
        {
          'from': r['paused_from'],
          'until': day(date(today()).subtract(const Duration(days: 1))),
        },
      ];
      r['paused'] = false;
    } else {
      r['paused'] = true;
      r['paused_from'] = today();
    }
    store.save('rule', r);
  }

  List<(Json, String)> dueDates(Json rule, String until) {
    final revisions = rows(rule['revisions'])
      ..sort(
        (a, b) =>
            (a['effective'] as String).compareTo(b['effective'] as String),
      );
    final result = <(Json, String)>[];
    if (rule['deleted'] == true) return result;
    for (var i = 0; i < revisions.length; i++) {
      final r = revisions[i], start = date(r['start'] as String);
      var y = start.year, m = start.month;
      while (day(DateTime.utc(y, m, 1)).compareTo(until) <= 0) {
        final on = occurrenceDate(y, m, r['anchor_day'] as int);
        final effective = r['effective'] as String;
        final inRange =
            on.compareTo(r['start'] as String) >= 0 &&
            on.compareTo(effective) >= 0 &&
            on.compareTo(until) <= 0 &&
            (r['end'] == null || on.compareTo(r['end'] as String) <= 0) &&
            (i + 1 == revisions.length ||
                on.compareTo(revisions[i + 1]['effective'] as String) < 0);
        final paused =
            rule['paused'] == true &&
                on.compareTo(rule['paused_from'] as String) >= 0 ||
            rows(rule['pauses']).any(
              (p) =>
                  on.compareTo(p['from'] as String) >= 0 &&
                  on.compareTo(p['until'] as String) <= 0,
            );
        if (inRange &&
            !paused &&
            (r['cycle'] == 'monthly' || m == r['anchor_month'])) {
          result.add((r, on));
        }
        m++;
        if (m > 12) {
          m = 1;
          y++;
        }
        require(y - start.year <= 150, '정기 내역 시작 연도를 확인해 주세요.');
      }
    }
    return result;
  }

  int generateDue({String? until}) {
    final cutoff = until ?? today();
    checkDate(cutoff);
    final batch = <(String, Json)>[];
    final knownEntries = store.events
        .where((e) => e['kind'] == 'entry')
        .toList();
    final ids = knownEntries.map((e) => e['entity']).toSet();
    // Restoring into a new ledger preserves existing occurrence identities.
    final occurrences = knownEntries
        .where((e) => e['data']['rule'] != null)
        .map(
          (e) =>
              '${e['data']['rule']}/${e['data']['scheduled_on'] ?? e['data']['date']}',
        )
        .toSet();
    for (final rule in store.all('rule')) {
      if (store.conflicts.containsKey('rule/${rule['id']}')) continue;
      for (final (r, on) in dueDates(rule, cutoff)) {
        if (store.get('account', r['account'] as String) == null ||
            r['type'] == 'transfer' &&
                store.get('account', r['destination'] as String) == null) {
          continue;
        }
        final id = stableId('${store.ledgerId}/occurrence/${rule['id']}/$on');
        if (ids.contains(id) || occurrences.contains('${rule['id']}/$on')) {
          continue;
        }
        final e = makeEntry(
          id: id,
          type: r['type'] as String,
          amount: r['amount'] as int,
          account: r['account'] as String,
          destination: r['destination'] as String?,
          on: on,
          memo: r['memo'] as String? ?? '',
          allocations: r['type'] == 'transfer'
              ? []
              : [
                  allocation(
                    r['amount'] as int,
                    r['category_name'] as String,
                    subcategory: r['subcategory_name'] as String?,
                    categoryId: r['category_id'] as String?,
                    subcategoryId: r['subcategory_id'] as String?,
                  ),
                ],
        );
        e['rule'] = rule['id'];
        e['rule_revision'] = r['id'];
        e['scheduled_on'] = on;
        batch.add(('entry', e));
      }
    }
    if (batch.isNotEmpty) store.saveBatch(batch);
    return batch.length;
  }

  (Json, String)? nextOccurrence(Json rule) {
    final known = store.events
        .where((e) => e['kind'] == 'entry' && e['data']['rule'] == rule['id'])
        .map((e) => e['data']['scheduled_on'] ?? e['data']['date'])
        .toSet();
    final now = date(today());
    return dueDates(rule, day(DateTime.utc(now.year + 2, now.month, now.day)))
        .where((e) => e.$2.compareTo(today()) >= 0 && !known.contains(e.$2))
        .firstOrNull;
  }

  void skipOccurrence(Json rule, String on) {
    final matches = dueDates(rule, on).where((e) => e.$2 == on);
    require(matches.isNotEmpty, '예정된 회차를 찾을 수 없어요.');
    final r = matches.single.$1;
    final id = stableId('${store.ledgerId}/occurrence/${rule['id']}/$on');
    require(store.get('entry', id) == null, '이미 기록된 회차는 내역에서 삭제해 주세요.');
    store.save('entry', {
      'id': id,
      'date': on,
      'type': r['type'],
      'amount': r['amount'],
      'memo': r['memo'] ?? '',
      'deleted': true,
      'rule': rule['id'],
      'rule_revision': r['id'],
      'scheduled_on': on,
      'postings': [
        {
          'account': r['account'],
          'delta': r['type'] == 'income' ? r['amount'] : -(r['amount'] as int),
        },
        if (r['type'] == 'transfer')
          {'account': r['destination'], 'delta': r['amount']},
      ],
      'allocations': r['type'] == 'transfer'
          ? <Json>[]
          : [
              allocation(
                r['amount'] as int,
                r['category_name'] as String,
                subcategory: r['subcategory_name'] as String?,
                categoryId: r['category_id'] as String?,
                subcategoryId: r['subcategory_id'] as String?,
              ),
            ],
      'shares': <Json>[],
      'receipts': <Json>[],
      'refunds': <Json>[],
    });
  }
}

const defaults = {
  'expense': {
    '식비': ['외식', '장보기', '카페'],
    '주거': ['월세', '관리비'],
    '쇼핑': ['의류', '생활용품'],
    '교통': ['대중교통', '택시'],
    '생활': ['통신', '생필품'],
    '여가': ['구독', '취미'],
    '의료': ['병원', '약'],
  },
  'income': {
    '급여': ['월급', '상여'],
    '부수입': ['용돈', '기타'],
    '금융': ['이자', '배당'],
  },
};
