class CurrencyFormat {
  final int id;
  final String name;
  final String prefixSymbol;
  final String suffixSymbol;
  final String decimalPoint;
  final String groupSeparator;

  const CurrencyFormat({
    required this.id,
    required this.name,
    required this.prefixSymbol,
    required this.suffixSymbol,
    required this.decimalPoint,
    required this.groupSeparator,
  });

  factory CurrencyFormat.fromRow(Map<String, Object?> row) {
    return CurrencyFormat(
      id: row['CURRENCYID'] as int,
      name: row['CURRENCYNAME'] as String? ?? '',
      prefixSymbol: row['PFX_SYMBOL'] as String? ?? '',
      suffixSymbol: row['SFX_SYMBOL'] as String? ?? '',
      decimalPoint: row['DECIMAL_POINT'] as String? ?? '.',
      groupSeparator: row['GROUP_SEPARATOR'] as String? ?? ' ',
    );
  }

  String format(double value) {
    final negative = value < 0;
    final abs = value.abs();
    final fixed = abs.toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => groupSeparator,
    );
    final formatted = '$intPart$decimalPoint${parts[1]}';
    final signed = negative ? '-$formatted' : formatted;
    return '$prefixSymbol$signed$suffixSymbol';
  }
}
