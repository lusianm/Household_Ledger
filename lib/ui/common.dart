import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/value.dart';
import 'money_input.dart';

String money(num value) => '${NumberFormat('#,##0', 'ko_KR').format(value)}원';
const chartColors = [
  Color(0xff009bc4),
  Color(0xff6ac8dc),
  Color(0xff526ed3),
  Color(0xffe7ad51),
  Color(0xff9f83d7),
  Color(0xff58aa91),
  Color(0xffd37e91),
];
void message(BuildContext context, Object text) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text('$text')));
Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('확인'),
          ),
        ],
      ),
    ) ??
    false;
Future<void> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) message(context, e);
  }
}

Widget panel(String title, Widget child, {Widget? trailing}) => Card(
  child: Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 18),
        child,
      ],
    ),
  ),
);
Widget empty(String title, String detail, {Widget? action}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
  child: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.receipt_long_outlined,
          size: 40,
          color: Color(0xff009bc4),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 16), child: action),
      ],
    ),
  ),
);
Widget selectField<T>(
  String label,
  T? value,
  List<(T, String)> values,
  ValueChanged<T?> changed,
) => DropdownButtonFormField<T>(
  key: ValueKey('$label/$value/${values.map((e) => e.$1).join()}'),
  initialValue: values.any((e) => e.$1 == value) ? value : null,
  isExpanded: true,
  decoration: InputDecoration(labelText: label),
  items: values
      .map(
        (e) => DropdownMenuItem(
          value: e.$1,
          child: Text(e.$2, overflow: TextOverflow.ellipsis),
        ),
      )
      .toList(),
  onChanged: changed,
);
Widget spaced(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(height: 16),
      children[i],
    ],
  ],
);
Future<String?> pickDay(
  BuildContext context,
  String initial, {
  bool future = false,
}) async {
  final selected = await showDatePicker(
    context: context,
    initialDate: date(initial),
    firstDate: DateTime(1900),
    lastDate: future ? DateTime(2150) : date(today()),
  );
  return selected == null ? null : day(selected);
}

class ExpenseChart extends StatelessWidget {
  final List<(String, int)> data;
  final ValueChanged<String>? onSelect;
  const ExpenseChart(this.data, {this.onSelect, super.key});
  @override
  Widget build(BuildContext context) {
    final positive = data.where((e) => e.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final total = positive.fold<int>(0, (a, b) => a + b.$2);
    if (total == 0) return empty('아직 지출이 없어요', '지출을 기록하면 분류별 비중을 보여드려요.');
    final donut = SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: DonutPainter(positive.map((e) => e.$2).toList()),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('지출 비중'),
              Text(
                money(total),
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final legend = Column(
      children: [
        for (var i = 0; i < positive.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 5,
              backgroundColor: chartColors[i % chartColors.length],
            ),
            title: Text(positive[i].$1),
            subtitle: Text(money(positive[i].$2)),
            trailing: Text(
              '${(positive[i].$2 / total * 100).toStringAsFixed(1)}%',
            ),
            onTap: onSelect == null ? null : () => onSelect!(positive[i].$1),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (c, b) => b.maxWidth > 500
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                donut,
                const SizedBox(width: 32),
                Expanded(child: legend),
              ],
            )
          : Column(children: [donut, const SizedBox(height: 20), legend]),
    );
  }
}

class DonutPainter extends CustomPainter {
  final List<int> values;
  DonutPainter(this.values);
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    var start = -math.pi / 2;
    final rect = Rect.fromLTWH(17, 17, size.width - 34, size.height - 34);
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = chartColors[i % chartColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 24,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(DonutPainter old) =>
      old.values.toString() != values.toString();
}

class PromptField {
  final String key, label;
  final String initial;
  final List<(String, String)>? options;
  final bool money, signed;
  const PromptField(
    this.key,
    this.label, {
    this.initial = '',
    this.options,
    this.money = false,
    this.signed = false,
  });
}

Future<Json?> prompt(
  BuildContext context,
  String title,
  List<PromptField> fields, {
  String? note,
}) => showDialog<Json>(
  context: context,
  builder: (_) => _Prompt(title, fields, note),
);

class _Prompt extends StatefulWidget {
  final String title;
  final List<PromptField> fields;
  final String? note;
  const _Prompt(this.title, this.fields, this.note);
  @override
  State<_Prompt> createState() => _PromptState();
}

class _PromptState extends State<_Prompt> {
  late final values = {
    for (final f in widget.fields)
      f.key: TextEditingController(
        text: f.money
            ? MoneyInputFormatter(signed: f.signed).format(f.initial)
            : f.initial,
      ),
  };
  @override
  void dispose() {
    for (final c in values.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: spaced([
          if (widget.note != null) Text(widget.note!),
          for (final f in widget.fields)
            if (f.options != null)
              selectField(f.label, values[f.key]!.text, f.options!, (v) {
                values[f.key]!.text = v ?? '';
                setState(() {});
              })
            else
              TextField(
                controller: values[f.key],
                keyboardType: f.money
                    ? TextInputType.numberWithOptions(signed: f.signed)
                    : null,
                inputFormatters: f.money
                    ? [MoneyInputFormatter(signed: f.signed)]
                    : null,
                decoration: InputDecoration(labelText: f.label),
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
        onPressed: () => Navigator.pop(context, {
          for (final e in values.entries) e.key: e.value.text,
        }),
        child: const Text('확인'),
      ),
    ],
  );
}
