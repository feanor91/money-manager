import 'package:flutter_test/flutter_test.dart';

import 'package:money_manager/data/mmex_database.dart';
import 'package:money_manager/data/mmex_repository.dart';

import 'test_helpers.dart';

/// resolveOrCreatePayee is what TransactionEditorSheet/RecurringEditorSheet's
/// "Tiers" field falls back to at save time when text was typed but never
/// explicitly selected/created (see SearchableSelectField.onTextChanged) -
/// so saving with a brand-new name still resolves to a real payee instead of
/// silently landing on "Tiers inconnu" (-1).
void main() {
  late MmexDatabase db;
  late MmexRepository repo;

  setUp(() async {
    db = await openBlankTestDb();
    repo = MmexRepository(db);
  });

  tearDown(() {
    db.dispose();
  });

  test('creates a new payee when no match exists', () {
    final id = repo.resolveOrCreatePayee(name: 'Carrefour');
    final payees = repo.getPayees(onlyActive: false);
    expect(payees.where((p) => p.id == id).single.name, 'Carrefour');
  });

  test('reuses an existing payee matched case-insensitively', () {
    final existingId = repo.insertPayee(name: 'Carrefour');
    final resolvedId = repo.resolveOrCreatePayee(name: 'CARREFOUR');
    expect(resolvedId, existingId);
    expect(repo.getPayees(onlyActive: false).length, 1);
  });

  test('trims whitespace before matching/creating', () {
    final existingId = repo.insertPayee(name: 'Carrefour');
    final resolvedId = repo.resolveOrCreatePayee(name: '  Carrefour  ');
    expect(resolvedId, existingId);
  });

  test('a new payee is created active with the given category', () {
    final categoryId = repo.insertCategory(name: 'Courses');
    final id = repo.resolveOrCreatePayee(name: 'Fnac', categoryId: categoryId);
    final payee = repo.getPayees(onlyActive: false).where((p) => p.id == id).single;
    expect(payee.active, true);
  });
}
