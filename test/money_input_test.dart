import 'package:chagok/ui/money_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const formatter = MoneyInputFormatter();
  TextEditingValue value(String text, int cursor) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: cursor),
  );
  test('amounts only contain digits and grouping separators', () {
    expect(formatter.format('10,000원 abc'), '10,000');
    expect(formatter.format('123456789012'), '123,456,789,012');
    expect(formatter.format('한글'), '');
    expect(formatter.format(''), '');
    expect(formatter.format('0'), '0');
    expect(formatter.format('-10000'), '10,000');
    expect(const MoneyInputFormatter(signed: true).format('-10000'), '-10,000');
    expect(const MoneyInputFormatter(signed: true).format('-'), '-');
  });
  test('insertion and replacement preserve the caret relative to digits', () {
    final inserted = formatter.formatEditUpdate(
      value('12,345', 2),
      value('129,345', 3),
    );
    expect(inserted.text, '129,345');
    expect(inserted.selection.baseOffset, 3);
    final appended = formatter.formatEditUpdate(
      value('123', 3),
      value('1234', 4),
    );
    expect(appended.text, '1,234');
    expect(appended.selection.baseOffset, 5);
    final replaced = formatter.formatEditUpdate(
      const TextEditingValue(
        text: '12,345',
        selection: TextSelection(baseOffset: 0, extentOffset: 6),
      ),
      value('9', 1),
    );
    expect(replaced.text, '9');
    expect(replaced.selection.baseOffset, 1);
  });
  test('backspace and forward delete across commas do not trap the caret', () {
    final backspace = formatter.formatEditUpdate(
      value('12,345', 3),
      value('12345', 2),
    );
    expect(backspace.text, '1,345');
    expect(backspace.selection.baseOffset, 1);
    final delete = formatter.formatEditUpdate(
      value('12,345', 2),
      value('12345', 2),
    );
    expect(delete.text, '1,245');
    expect(delete.selection.baseOffset, 3);
    expect(formatter.formatEditUpdate(value('1', 1), value('', 0)).text, '');
  });
}
