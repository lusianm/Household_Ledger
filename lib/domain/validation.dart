import 'value.dart';

void validateDocument(String kind, Json d) {
  require(d['id'] is String && (d['id'] as String).isNotEmpty, '기록 ID가 필요해요.');
  require(d['deleted'] == null || d['deleted'] is bool, '삭제 상태를 확인해 주세요.');
  void text(String field, {bool optional = false}) => require(
    optional && d[field] == null ||
        d[field] is String && (d[field] as String).length <= 20000,
    '$field 형식이 올바르지 않아요.',
  );
  switch (kind) {
    case 'account':
      text('name');
      require((d['name'] as String).trim().isNotEmpty, '계좌 이름을 입력해 주세요.');
      require(
        ['bank', 'cash', 'savings', 'card'].contains(d['kind']),
        '계좌 종류를 확인해 주세요.',
      );
      require(
        d['opening'] is int && (d['opening'] as int).abs() <= maxMoney,
        '초기 잔액을 확인해 주세요.',
      );
      require(d['liquid'] is bool, '사용 가능액 포함 여부를 확인해 주세요.');
      date(d['date'] as String);
    case 'category':
      text('name');
      require((d['name'] as String).trim().isNotEmpty, '분류 이름을 입력해 주세요.');
      require(['income', 'expense'].contains(d['type']), '분류 유형을 확인해 주세요.');
      text('parent', optional: true);
      require(d['parent'] != d['id'], '자기 자신을 상위 분류로 지정할 수 없어요.');
    case 'entry':
      _entry(d);
    case 'debt':
      text('person');
      require((d['person'] as String).trim().isNotEmpty, '상대방을 입력해 주세요.');
      require(['lent', 'borrowed'].contains(d['direction']), '빚 종류를 확인해 주세요.');
      text('memo');
      date(d['date'] as String);
      if (d['due'] != null) date(d['due'] as String);
      final events = rows(d['events']);
      _unique(events);
      var principal = 0;
      final ordered = events.indexed.toList()
        ..sort((a, b) {
          final byDate = (a.$2['date'] as String).compareTo(
            b.$2['date'] as String,
          );
          return byDate == 0 ? a.$1.compareTo(b.$1) : byDate;
        });
      for (final (_, e) in ordered.where((e) => e.$2['voided'] != true)) {
        positiveMoney(e['amount']);
        date(e['date'] as String);
        require(['add', 'repay'].contains(e['type']), '빚 기록 유형을 확인해 주세요.');
        principal += (e['amount'] as int) * (e['type'] == 'repay' ? -1 : 1);
        require(principal >= 0, '상환 금액이 남은 원금을 초과해요.');
      }
    case 'rule':
      final revisions = rows(d['revisions']);
      require(revisions.isNotEmpty, '정기 규칙이 필요해요.');
      _unique(revisions);
      for (final r in revisions) {
        require(
          ['income', 'expense', 'transfer'].contains(r['type']),
          '정기 거래 유형을 확인해 주세요.',
        );
        require(['monthly', 'yearly'].contains(r['cycle']), '반복 주기를 확인해 주세요.');
        positiveMoney(r['amount']);
        date(r['start'] as String);
        date(r['effective'] as String);
        require(
          r['anchor_day'] is int &&
              r['anchor_day'] >= 1 &&
              r['anchor_day'] <= 31,
          '반복 일을 확인해 주세요.',
        );
        require(
          r['anchor_month'] is int &&
              r['anchor_month'] >= 1 &&
              r['anchor_month'] <= 12,
          '반복 월을 확인해 주세요.',
        );
        if (r['end'] != null) {
          require(
            !date(r['end'] as String).isBefore(date(r['start'] as String)),
            '종료일은 시작일 이후여야 해요.',
          );
        }
        require(r['account'] is String, '연결 계좌를 선택해 주세요.');
        if (r['type'] == 'transfer') {
          require(
            r['destination'] is String && r['destination'] != r['account'],
            '서로 다른 출발·도착 계좌를 선택해 주세요.',
          );
        } else {
          _allocation(r);
        }
      }
    case 'budget':
      require(
        RegExp(r'^\d{4}-\d{2}$').hasMatch(d['month'] as String),
        '예산 월을 확인해 주세요.',
      );
      nonnegativeMoney(d['amount']);
    case 'settings':
      require(
        d['theme'] == null || ['system', 'light', 'dark'].contains(d['theme']),
        '화면 설정이 올바르지 않아요.',
      );
    default:
      throw const LedgerException('지원하지 않는 데이터 종류입니다.');
  }
}

void _unique(List<Json> list) => require(
  list.map((e) => e['id']).toSet().length == list.length &&
      list.every((e) => e['id'] is String),
  '중복되거나 없는 기록 ID가 있어요.',
);
void _allocation(Json a) {
  nonnegativeMoney(a['amount']);
  require(
    a['category_name'] is String &&
        (a['category_name'] as String).trim().isNotEmpty,
    '대분류를 선택해 주세요.',
  );
  require(
    a['subcategory_name'] == null ||
        a['subcategory_name'] is String &&
            (a['subcategory_name'] as String).trim().isNotEmpty,
    '소분류를 확인해 주세요.',
  );
  require(
    a['subcategory_id'] == null ||
        a['category_id'] != null && a['subcategory_name'] != null,
    '소분류의 상위 분류가 필요해요.',
  );
}

void _entry(Json d) {
  require(
    ['income', 'expense', 'transfer', 'adjustment'].contains(d['type']),
    '거래 유형을 확인해 주세요.',
  );
  positiveMoney(d['amount']);
  date(d['date'] as String);
  require(d['memo'] is String, '메모 형식을 확인해 주세요.');
  final posts = rows(d['postings']),
      allocations = rows(d['allocations']),
      shares = rows(d['shares']);
  require(
    posts.every(
      (p) =>
          p['account'] is String &&
          p['delta'] is int &&
          (p['delta'] as int).abs() <= maxMoney,
    ),
    '계좌 증감 형식을 확인해 주세요.',
  );
  final amount = d['amount'] as int;
  if (d['type'] == 'transfer') {
    require(
      posts.length == 2 &&
          posts[0]['account'] != posts[1]['account'] &&
          posts[0]['delta'] == -amount &&
          posts[1]['delta'] == amount &&
          allocations.isEmpty &&
          shares.isEmpty,
      '이동 내역의 양쪽 금액을 확인해 주세요.',
    );
  } else {
    require(posts.length == 1, '계좌를 선택해 주세요.');
    if (d['type'] == 'adjustment') {
      require(
        (posts.single['delta'] as int).abs() == amount &&
            allocations.isEmpty &&
            shares.isEmpty,
        '잔액 조정 내용을 확인해 주세요.',
      );
    } else {
      require(
        posts.single['delta'] == (d['type'] == 'income' ? amount : -amount),
        '거래 금액과 계좌 증감이 일치하지 않아요.',
      );
      for (final a in allocations) {
        _allocation(a);
      }
      _unique(shares);
      for (final s in shares) {
        positiveMoney(s['amount']);
        require(
          s['person'] is String && (s['person'] as String).trim().isNotEmpty,
          '정산 상대방을 입력해 주세요.',
        );
      }
      require(d['type'] == 'expense' || shares.isEmpty, '정산은 지출에 연결해 주세요.');
      require(
        sumMoney(allocations.map((a) => a['amount'] as int)) +
                sumMoney(shares.map((s) => s['amount'] as int)) ==
            amount,
        '내 부담과 상대방 몫의 합계가 결제액과 같아야 해요.',
      );
    }
  }
  final receipts = rows(d['receipts']);
  _unique(receipts);
  for (final r in receipts) {
    positiveMoney(r['amount']);
    date(r['date'] as String);
    require(
      (r['date'] as String).compareTo(d['date'] as String) >= 0,
      '정산 수령일은 결제일 이후여야 해요.',
    );
    require(
      r['account'] is String && shares.any((s) => s['id'] == r['share']),
      '정산 연결을 확인해 주세요.',
    );
  }
  for (final s in shares) {
    require(
      sumMoney(
            receipts
                .where((r) => r['voided'] != true && r['share'] == s['id'])
                .map((r) => r['amount'] as int),
          ) <=
          s['amount'],
      '받은 금액이 청구 금액을 초과해요.',
    );
  }
  final refunds = rows(d['refunds']);
  _unique(refunds);
  require(
    refunds.isEmpty || d['type'] == 'expense' && shares.isEmpty,
    '공동 결제의 환불은 정산을 먼저 정리해 주세요.',
  );
  final activeRefunds = refunds.where((r) => r['voided'] != true);
  require(
    sumMoney(activeRefunds.map((r) => r['amount'] as int)) <= amount,
    '환불 금액이 결제 금액을 초과해요.',
  );
  for (final r in refunds) {
    positiveMoney(r['amount']);
    date(r['date'] as String);
    require(r['account'] is String, '환불 계좌를 선택해 주세요.');
    require(
      (r['date'] as String).compareTo(d['date'] as String) >= 0,
      '환불일은 결제일 이후여야 해요.',
    );
    require(
      sumMoney(rows(r['allocations']).map((a) => a['amount'] as int)) ==
          -(r['amount'] as int),
      '환불 분류 금액을 확인해 주세요.',
    );
  }
}
