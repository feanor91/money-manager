import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';
import 'package:money_manager/models/recurrence.dart';
import 'package:money_manager/models/transaction.dart';

import 'test_helpers.dart';

/// Backs the "Gestion des tiers" settings screen (payees_screen.dart,
/// 2026-08-23): payeeUsageCount/renamePayee/deletePayee.
void main() {
  late MmexDatabase db;
  late MmexRepository repo;
  late int accountId;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
    accountId = repo.insertAccount(
        name: 'Compte test', type: 'Checking', initialBalance: 1000, currencyId: 2);
  });

  tearDown(() => db.dispose());

  test('a payee with no transaction or recurring bill has usage count 0', () {
    final payeeId = repo.insertPayee(name: 'Carrefour');
    expect(repo.payeeUsageCount(payeeId), 0);
  });

  test('payeeUsageCount counts real ledger transactions', () {
    final payeeId = repo.insertPayee(name: 'Carrefour');
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 40,
      date: DateTime.now(),
    );
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 25,
      date: DateTime.now(),
    );
    expect(repo.payeeUsageCount(payeeId), 2);
  });

  test('payeeUsageCount also counts recurring bill templates', () {
    final payeeId = repo.insertPayee(name: 'Netflix');
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 15,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    expect(repo.payeeUsageCount(payeeId), 1);
  });

  test('payeeUsageCount sums both sources together', () {
    final payeeId = repo.insertPayee(name: 'Boursorama');
    repo.insertTransaction(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 10,
      date: DateTime.now(),
    );
    repo.insertBillDeposit(
      accountId: accountId,
      payeeId: payeeId,
      transCode: TransCode.withdrawal,
      amount: 10,
      nextOccurrence: DateTime.now(),
      period: RecurrencePeriod.monthly,
      autoExecute: RecurrenceAutoExecute.manual,
    );
    expect(repo.payeeUsageCount(payeeId), 2);
  });

  test('renamePayee updates the name in place, keeping the same id', () {
    final payeeId = repo.insertPayee(name: 'Ancien nom');
    repo.renamePayee(payeeId, 'Nouveau nom');
    final payee = repo.getPayees(onlyActive: false).firstWhere((p) => p.id == payeeId);
    expect(payee.name, 'Nouveau nom');
  });

  test('deletePayee removes an unused payee', () {
    final payeeId = repo.insertPayee(name: 'Jamais utilisé');
    repo.deletePayee(payeeId);
    expect(repo.getPayees(onlyActive: false).where((p) => p.id == payeeId), isEmpty);
  });

  group('previewBulkRenamePayees/applyBulkRenamePayees', () {
    test('prefixOnly strips a leading match only, trimming the leftover space', () {
      final matching = repo.insertPayee(name: 'CB Boucherie Martin');
      final untouched = repo.insertPayee(name: 'Boulangerie CB');
      final preview = repo.previewBulkRenamePayees(
          search: 'CB ', replacement: '', prefixOnly: true);
      expect(preview, hasLength(1));
      expect(preview.single.payee.id, matching);
      expect(preview.single.newName, 'Boucherie Martin');
      final result = repo.applyBulkRenamePayees(preview);
      expect(result.renamed, 1);
      expect(result.merged, 0);
      final names = {for (final p in repo.getPayees(onlyActive: false)) p.id: p.name};
      expect(names[matching], 'Boucherie Martin');
      expect(names[untouched], 'Boulangerie CB');
    });

    test('without prefixOnly, replaces the match anywhere in the name', () {
      repo.insertPayee(name: 'Virement CB reçu');
      final preview = repo.previewBulkRenamePayees(
          search: 'CB ', replacement: '', prefixOnly: false);
      expect(preview.single.newName, 'Virement reçu');
      repo.applyBulkRenamePayees(preview);
      expect(repo.getPayees(onlyActive: false).single.name, 'Virement reçu');
    });

    test('a rename that collides with an existing payee merges instead of erroring', () {
      final cbBoucherie = repo.insertPayee(name: 'CB Boucherie');
      final realBoucherie = repo.insertPayee(name: 'Boucherie');
      repo.insertTransaction(
        accountId: accountId,
        payeeId: cbBoucherie,
        transCode: TransCode.withdrawal,
        amount: 12,
        date: DateTime.now(),
      );
      final preview = repo.previewBulkRenamePayees(
          search: 'CB ', replacement: '', prefixOnly: true);
      final result = repo.applyBulkRenamePayees(preview);
      expect(result.renamed, 0);
      expect(result.merged, 1);
      final remaining = repo.getPayees(onlyActive: false);
      expect(remaining, hasLength(1));
      expect(remaining.single.id, realBoucherie);
      // La transaction du tiers fusionné a bien été reportée sur le survivant.
      expect(repo.payeeUsageCount(realBoucherie), 1);
    });

    test('two payees in the same batch colliding onto the same new name merge together', () {
      final first = repo.insertPayee(name: 'CB Pharmacie Centrale');
      final second = repo.insertPayee(name: 'PHARMACIE CENTRALE');
      final preview = repo.previewBulkRenamePayees(
          search: 'CB ', replacement: '', prefixOnly: true);
      expect(preview, hasLength(1)); // seul "CB Pharmacie Centrale" change de nom
      final result = repo.applyBulkRenamePayees(preview);
      expect(result.merged, 1);
      final remaining = repo.getPayees(onlyActive: false);
      expect(remaining, hasLength(1));
      expect(remaining.single.id, second);
      expect(remaining.single.name, 'PHARMACIE CENTRALE');
      expect(first, isNot(second));
    });

    test('a payee that would become empty is left out of the preview', () {
      repo.insertPayee(name: 'CB');
      final preview = repo.previewBulkRenamePayees(
          search: 'CB', replacement: '', prefixOnly: true);
      expect(preview, isEmpty);
    });

    test('an empty search string previews nothing', () {
      repo.insertPayee(name: 'CB Boucherie Martin');
      expect(
        repo.previewBulkRenamePayees(search: '', replacement: '', prefixOnly: true),
        isEmpty,
      );
    });
  });
}
