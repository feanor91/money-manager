import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int sourceAccountId;
  late int destAccountId;
  late int categoryId;
  late int payeeId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    sourceAccountId = repo.insertAccount(
        name: 'Crédit Agricole', type: 'Checking', initialBalance: 1000, currencyId: 2);
    destAccountId = repo.insertAccount(
        name: 'Boursorama', type: 'Checking', initialBalance: 0, currencyId: 2);
    categoryId = repo.insertCategory(name: 'Salaire Bruno');
    payeeId = repo.insertPayee(name: 'Virement interne');
  });

  tearDown(() {
    db.dispose();
  });

  group('categorySpendForPeriod includeCategorizedTransfersAsExpense '
      '(2026-09-05, "un virement de 700€ ... c\'est une dépense sur le '
      'Crédit Agricole")', () {
    test('a categorized transfer is ignored by default - unchanged '
        'behavior for every existing caller', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );

      final totals = repo.categorySpendForPeriod(
          DateTime(2026, 8, 1), DateTime(2026, 9, 1),
          accountId: sourceAccountId);

      expect(totals[categoryId], isNull);
    });

    test('counts as an expense on the source account when opted in', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );

      final totals = repo.categorySpendForPeriod(
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        accountId: sourceAccountId,
        includeCategorizedTransfersAsExpense: true,
      );

      expect(totals[categoryId], 700.0);
    });

    test('never counts on the destination account - no double-booking, '
        'no accidental "expense" where it\'s actually income', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );

      final totals = repo.categorySpendForPeriod(
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        accountId: destAccountId,
        includeCategorizedTransfersAsExpense: true,
      );

      expect(totals[categoryId], isNull);
    });

    test('still counted correctly as income on the destination account, '
        'never on the source - incomeForPeriod is untouched by this whole '
        'feature, exercised here just to confirm both sides agree', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );

      final destIncome = repo.incomeForPeriod(
          DateTime(2026, 8, 1), DateTime(2026, 9, 1), accountId: destAccountId);
      final sourceIncome = repo.incomeForPeriod(
          DateTime(2026, 8, 1), DateTime(2026, 9, 1), accountId: sourceAccountId);

      expect(destIncome, 700.0);
      expect(sourceIncome, 0.0);
    });

    test('an uncategorized transfer still never counts, even opted in - '
        'nothing to attribute it to', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        date: DateTime(2026, 8, 25), // no categoryId
      );

      final totals = repo.categorySpendForPeriod(
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        accountId: sourceAccountId,
        includeCategorizedTransfersAsExpense: true,
      );

      expect(totals, isEmpty);
    });

    test('is a no-op without an accountId ("tous les comptes") - no '
        'sensible source/destination side to pick', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );

      final totals = repo.categorySpendForPeriod(
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        accountId: null,
        includeCategorizedTransfersAsExpense: true,
      );

      expect(totals[categoryId], isNull);
    });

    test('a real withdrawal in the same category still counts normally '
        'alongside a categorized transfer', () {
      repo.insertTransaction(
        accountId: sourceAccountId,
        toAccountId: destAccountId,
        payeeId: payeeId,
        transCode: TransCode.transfer,
        amount: 700,
        categoryId: categoryId,
        date: DateTime(2026, 8, 25),
      );
      repo.insertTransaction(
        accountId: sourceAccountId,
        payeeId: payeeId,
        transCode: TransCode.withdrawal,
        amount: 50,
        categoryId: categoryId,
        date: DateTime(2026, 8, 10),
      );

      final totals = repo.categorySpendForPeriod(
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        accountId: sourceAccountId,
        includeCategorizedTransfersAsExpense: true,
      );

      expect(totals[categoryId], 750.0);
    });
  });
}
