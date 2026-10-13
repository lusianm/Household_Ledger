import 'package:flutter/services.dart';

class MoneyInputFormatter extends TextInputFormatter {
  final bool signed;
  const MoneyInputFormatter({this.signed = false});

  String format(String text) => formatEditUpdate(
    TextEditingValue.empty,
    TextEditingValue(text: text),
  ).text;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text;
    var selection = newValue.selection;
    // Deleting a separator should remove a digit, rather than restore the comma.
    if (oldValue.selection.isCollapsed &&
        selection.isCollapsed &&
        oldValue.text.length == text.length + 1) {
      final offset = selection.baseOffset;
      if (offset >= 0 &&
          offset < oldValue.text.length &&
          oldValue.text[offset] == ',' &&
          oldValue.text.replaceRange(offset, offset + 1, '') == text) {
        final backward = oldValue.selection.baseOffset > offset;
        final digit = backward ? offset - 1 : offset;
        if (digit >= 0 &&
            digit < text.length &&
            RegExp(r'[0-9]').hasMatch(text[digit])) {
          text = text.replaceRange(digit, digit + 1, '');
          selection = TextSelection.collapsed(
            offset: backward ? digit : offset,
          );
        }
      }
    }
    final negative = signed && text.startsWith('-');
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (match) => '${match[1]},',
    );
    final formatted = '${negative ? '-' : ''}$grouped';
    int cursor(int offset) {
      if (offset < 0) return formatted.length;
      final prefix = text.substring(0, offset.clamp(0, text.length));
      final count = prefix.replaceAll(RegExp(r'[^0-9]'), '').length;
      if (count == 0) return negative && offset > 0 ? 1 : 0;
      var seen = 0;
      for (var i = 0; i < formatted.length; i++) {
        if (RegExp(r'[0-9]').hasMatch(formatted[i]) && ++seen == count) {
          return i + 1;
        }
      }
      return formatted.length;
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection(
        baseOffset: cursor(selection.baseOffset),
        extentOffset: cursor(selection.extentOffset),
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
    );
  }
}
