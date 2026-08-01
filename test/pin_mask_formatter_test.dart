import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/screens/pin_lock_screen.dart';

void main() {
  group('pinMaskFormatter', () {
    test('masks each typed character while tracking the real value', () {
      var real = '';
      final formatter = pinMaskFormatter(
        getValue: () => real,
        setValue: (v) => real = v,
      );

      var value = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '1', selection: TextSelection.collapsed(offset: 1)),
      );
      expect(value.text, '•');
      expect(real, '1');

      value = formatter.formatEditUpdate(
        value,
        TextEditingValue(text: '${value.text}2', selection: const TextSelection.collapsed(offset: 2)),
      );
      expect(value.text, '••');
      expect(real, '12');

      value = formatter.formatEditUpdate(
        value,
        TextEditingValue(text: '${value.text}34', selection: const TextSelection.collapsed(offset: 4)),
      );
      expect(value.text, '••••');
      expect(real, '1234');
    });

    test('backspace removes the last real character, not a dot literally', () {
      var real = '1234';
      final formatter = pinMaskFormatter(
        getValue: () => real,
        setValue: (v) => real = v,
      );

      final value = formatter.formatEditUpdate(
        const TextEditingValue(text: '••••', selection: TextSelection.collapsed(offset: 4)),
        const TextEditingValue(text: '•••', selection: TextSelection.collapsed(offset: 3)),
      );
      expect(value.text, '•••');
      expect(real, '123');
    });

    test('a whole value arriving at once (paste/autofill/enterText) is treated as newly typed', () {
      var real = '';
      final formatter = pinMaskFormatter(
        getValue: () => real,
        setValue: (v) => real = v,
      );

      final value = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '1234', selection: TextSelection.collapsed(offset: 4)),
      );
      expect(value.text, '••••');
      expect(real, '1234');
    });

    test('clearing the field clears the tracked real value', () {
      var real = '1234';
      final formatter = pinMaskFormatter(
        getValue: () => real,
        setValue: (v) => real = v,
      );

      final value = formatter.formatEditUpdate(
        const TextEditingValue(text: '••••', selection: TextSelection.collapsed(offset: 4)),
        TextEditingValue.empty,
      );
      expect(value.text, '');
      expect(real, '');
    });

    test('never leaks the real digits into the displayed/DOM value', () {
      var real = '';
      final formatter = pinMaskFormatter(
        getValue: () => real,
        setValue: (v) => real = v,
      );

      final value = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '13', selection: TextSelection.collapsed(offset: 2)),
      );
      expect(value.text, isNot(contains('1')));
      expect(value.text, isNot(contains('3')));
      expect(value.text, '••');
    });
  });
}
