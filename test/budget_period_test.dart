import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/models/budget_period.dart';

void main() {
  group('nextForecastDay', () {
    test('returns this month\'s occurrence when it has not passed yet', () {
      expect(nextForecastDay(DateTime(2026, 8, 3), 24), DateTime(2026, 8, 24));
    });

    test('returns next month\'s occurrence when this month\'s has already passed', () {
      expect(nextForecastDay(DateTime(2026, 8, 25), 24), DateTime(2026, 9, 24));
    });

    test('the forecast day itself counts as "not yet passed" - inclusive, not exclusive', () {
      expect(nextForecastDay(DateTime(2026, 8, 24), 24), DateTime(2026, 8, 24));
    });

    test('clamps to the last real day of a shorter month', () {
      // April has 30 days - day 31 clamps down rather than rolling into May.
      expect(nextForecastDay(DateTime(2026, 4, 3), 31), DateTime(2026, 4, 30));
    });

    test('rolling into the next month also clamps if that one is shorter', () {
      // Reference already past day 31 in a 31-day month (January) - rolls to
      // February, which clamps to 28 (2026 is not a leap year).
      expect(nextForecastDay(DateTime(2026, 1, 31, 12), 31), DateTime(2026, 1, 31));
      expect(nextForecastDay(DateTime(2026, 2, 1), 31), DateTime(2026, 2, 28));
    });
  });
}
