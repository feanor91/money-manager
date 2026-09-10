import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager_core/data/mmex_database.dart';
import 'package:money_manager_core/data/mmex_repository.dart';

import 'test_helpers.dart';

void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;
  late int categoryId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Crédit Agricole', type: 'Checking', initialBalance: 1000, currencyId: 2);
    // "Assurances" collides with a category the blank test schema already
    // seeds (like "Revenus" elsewhere) - use a name that's unique to this
    // test file instead.
    categoryId = repo.insertCategory(name: 'Assurances Test');
  });

  tearDown(() {
    db.dispose();
  });

  group('BudgetEnvelope.manualOverride (2026-09-06, "je veux changer le '
      'montant prévu pour assurance et la sauvegarde ne fonctionne pas" - '
      'the recalculate-from-history button was silently a no-op on an '
      '"auto" envelope with no way to make a typed amount stick)', () {
    test('defaults to false for a brand-new envelope', () {
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 50);
      final envelope = repo.getBudgetEnvelopes(accountId).single;
      expect(envelope.manualOverride, isFalse);
    });

    test('round-trips true when explicitly set on an existing envelope', () {
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 50);
      final id = repo.getBudgetEnvelopes(accountId).single.id;

      repo.upsertBudgetEnvelope(
        id: id,
        accountId: accountId,
        categoryId: categoryId,
        amount: 294.95,
        manualOverride: true,
      );

      final envelope = repo.getBudgetEnvelopes(accountId).single;
      expect(envelope.manualOverride, isTrue);
      expect(envelope.amount, 294.95);
    });

    test('omitting manualOverride on an update leaves the stored flag '
        'untouched, same as the existing NAME sentinel convention', () {
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 50);
      final id = repo.getBudgetEnvelopes(accountId).single.id;
      repo.upsertBudgetEnvelope(
        id: id,
        accountId: accountId,
        categoryId: categoryId,
        amount: 60,
        manualOverride: true,
      );

      // A later save that doesn't mention manualOverride at all (e.g. a
      // caller that never learned about this field) must not silently
      // reset it back to false.
      repo.upsertBudgetEnvelope(id: id, accountId: accountId, categoryId: categoryId, amount: 70);

      final envelope = repo.getBudgetEnvelopes(accountId).single;
      expect(envelope.manualOverride, isTrue);
      expect(envelope.amount, 70.0);
    });

    test('can be cleared back to false', () {
      repo.upsertBudgetEnvelope(accountId: accountId, categoryId: categoryId, amount: 50);
      final id = repo.getBudgetEnvelopes(accountId).single.id;
      repo.upsertBudgetEnvelope(
        id: id,
        accountId: accountId,
        categoryId: categoryId,
        amount: 60,
        manualOverride: true,
      );

      repo.upsertBudgetEnvelope(
        id: id,
        accountId: accountId,
        categoryId: categoryId,
        amount: 60,
        manualOverride: false,
      );

      final envelope = repo.getBudgetEnvelopes(accountId).single;
      expect(envelope.manualOverride, isFalse);
    });
  });
}
