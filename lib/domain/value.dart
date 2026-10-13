import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;
const uuid = Uuid();
const maxMoney = 999999999999;

class LedgerException implements Exception {
  final String message;
  const LedgerException(this.message);
  @override
  String toString() => message;
}

void require(bool condition, String message) {
  if (!condition) throw LedgerException(message);
}

Json copyJson(Json value) => jsonDecode(jsonEncode(value)) as Json;
List<Json> rows(dynamic value) => (value as List? ?? [])
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();
int sumMoney(Iterable<int> values) => values.fold(0, (a, b) => a + b);
int parseMoney(String text, {bool signed = false}) {
  final raw = text.replaceAll(',', '').trim();
  require(
    RegExp(signed ? r'^-?\d+$' : r'^\d+$').hasMatch(raw),
    '금액은 원 단위 정수로 입력해 주세요.',
  );
  final value = int.tryParse(raw);
  require(value != null && value.abs() <= maxMoney, '금액 범위를 확인해 주세요.');
  return value!;
}

String day(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String today() => day(DateTime.now().toUtc().add(const Duration(hours: 9)));
DateTime date(String value) {
  final result = DateTime.tryParse(value);
  require(
    result != null && day(result) == value && value.length == 10,
    '날짜 형식을 확인해 주세요.',
  );
  return DateTime.utc(result!.year, result.month, result.day);
}

String monthOf(String value) => value.substring(0, 7);
String occurrenceDate(int year, int month, int anchor) {
  final last = DateTime.utc(year, month + 1, 0).day;
  return day(DateTime.utc(year, month, anchor > last ? last : anchor));
}

dynamic canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

String digest(dynamic value) =>
    sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();
String stableId(String value) => uuid.v5(Namespace.oid.value, value);
const typeLabels = {
  'income': '수입',
  'expense': '지출',
  'transfer': '이동',
  'receipt': '정산 수령',
  'debt': '빚 원금',
  'opening': '초기 잔액',
  'adjustment': '잔액 조정',
  'refund': '환불',
};
String entryLabel(Json e) {
  final allocations = rows(e['allocations']);
  if (allocations.isNotEmpty) {
    final a = allocations.first;
    return '${a['category_name']}${a['subcategory_name'] == null ? '' : ' › ${a['subcategory_name']}'}';
  }
  return typeLabels[e['type']] ?? '내역';
}

void positiveMoney(dynamic value) => require(
  value is int && value > 0 && value <= maxMoney,
  '금액은 1원 이상으로 입력해 주세요.',
);
void nonnegativeMoney(dynamic value) =>
    require(value is int && value >= 0 && value <= maxMoney, '금액을 확인해 주세요.');
