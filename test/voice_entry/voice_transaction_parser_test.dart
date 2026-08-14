import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/models/category.dart';
import 'package:money_manager/models/payee.dart';
import 'package:money_manager/models/transaction.dart';
import 'package:money_manager/services/voice_entry/voice_transaction_parser.dart';

void main() {
  final now = DateTime(2026, 8, 5, 10);

  const alimentation = Category(id: 1, name: 'Alimentation', active: true);
  const essence = Category(id: 2, name: 'Essence', active: true);
  const categories = [alimentation, essence];

  // Carrefour defaults to Alimentation, so matching the payee alone should
  // be enough to also fill in a sensible category.
  const carrefour = Payee(id: 20, name: 'Carrefour', active: true, categoryId: 1);
  const employeur = Payee(id: 21, name: 'Mon Employeur', active: true);
  // Deliberately shares a name with the "Boursorama Perso" account below -
  // this exact ambiguity (a bank both as a payee, for its own fees, and as
  // an account) is what exposed the bug this covers.
  const boursoramaPayee = Payee(id: 22, name: 'Boursorama', active: true);
  const payees = [carrefour, employeur, boursoramaPayee];

  // Deliberately multi-word, matching how real accounts actually get named
  // in this app (confirmed 2026-08-07 by the user's own real account
  // names) - nobody says a full "Boursorama Perso" or "Crédit Agricole
  // Compte Commun" out loud, which is exactly what broke the first version
  // of this feature (an exact whole-name match via bestNameMatch).
  const boursorama = Account(
    id: 30,
    name: 'Boursorama Perso',
    type: 'Checking',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: false,
  );
  const livretA = Account(
    id: 31,
    name: 'Livret A',
    type: 'Savings',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: false,
  );
  const caCommun = Account(
    id: 32,
    name: 'Crédit Agricole Compte Commun',
    type: 'Checking',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: false,
  );
  const caCodevi = Account(
    id: 33,
    name: 'Crédit Agricole Codevi',
    type: 'Savings',
    status: 'Open',
    initialBalance: 0,
    currencyId: 1,
    favorite: false,
  );
  const accounts = [boursorama, livretA, caCommun, caCodevi];

  VoiceTransactionDraft parse(String transcript, {List<Account> withAccounts = accounts}) =>
      parseVoiceTransaction(
        transcript,
        payees: payees,
        categories: categories,
        accounts: withAccounts,
        now: now,
      );

  test('extracts amount, date and payee from a typical expense sentence', () {
    // Digits, not "trente-cinq" - this is the already speech-recognized
    // transcript, and Android's on-device recognizer normally transcribes a
    // dictated number as digits (see parseVoiceTransaction's doc comment).
    final draft = parse('35 euros chez Carrefour hier');
    expect(draft.amount, 35);
    expect(draft.date, DateTime(2026, 8, 4));
    expect(draft.payeeId, 20);
    expect(draft.transCode, TransCode.withdrawal);
  });

  test('a matched payee fills in its own default category', () {
    final draft = parse('12 euros chez Carrefour');
    expect(draft.categoryId, 1);
  });

  test('an explicit category word wins over the payee default category', () {
    final draft = parse('50 euros chez Carrefour pour essence');
    expect(draft.categoryId, 2);
  });

  test('decimal amount with a comma is parsed correctly', () {
    final draft = parse('35,50 euros chez Carrefour');
    expect(draft.amount, 35.5);
  });

  test(
      '"12 euros 35" (cents spoken as a separate trailing number) is parsed as 12,35€ - '
      'regression test for the 2026-08-13 report of it landing on 12,00€', () {
    final draft = parse('12 euros 35 chez Carrefour');
    expect(draft.amount, 12.35);
  });

  test('"12 euros 35 centimes" (the word "centimes" said explicitly) still parses as 12,35€', () {
    final draft = parse('12 euros 35 centimes chez Carrefour');
    expect(draft.amount, 12.35);
  });

  test('"12 euros et 35" ("et" said between the two numbers) still parses as 12,35€', () {
    final draft = parse('12 euros et 35 chez Carrefour');
    expect(draft.amount, 12.35);
  });

  test('a single spoken cents digit is treated as centimes, not tenths - "12 euros 5" is 12,05€, '
      'not 12,50€', () {
    final draft = parse('12 euros 5 chez Carrefour');
    expect(draft.amount, 12.05);
  });

  test('a euro sign is recognized the same as the word "euros"', () {
    final draft = parse('20€ chez Carrefour');
    expect(draft.amount, 20);
  });

  test('the currency-tagged number wins over an unrelated number in the sentence', () {
    final draft = parse('15 euros chez Carrefour le 3 aout');
    expect(draft.amount, 15);
  });

  test('no amount found leaves it null and keeps the raw transcript as notes', () {
    final draft = parse('chez Carrefour hier');
    expect(draft.amount, isNull);
    expect(draft.notes, 'chez Carrefour hier');
  });

  test('amount found means no notes fallback is needed', () {
    final draft = parse('10 euros chez Carrefour');
    expect(draft.notes, isNull);
  });

  test('"avant-hier" resolves to two days before now', () {
    final draft = parse('8 euros avant-hier');
    expect(draft.date, DateTime(2026, 8, 3));
  });

  test('no date word defaults to today', () {
    final draft = parse('8 euros chez Carrefour');
    expect(draft.date, DateTime(2026, 8, 5));
  });

  test('an income keyword is detected as a deposit', () {
    final draft = parse('reçu 200 euros de Mon Employeur');
    expect(draft.transCode, TransCode.deposit);
    expect(draft.payeeId, 21);
  });

  test('no income keyword defaults to a withdrawal', () {
    final draft = parse('200 euros chez Carrefour');
    expect(draft.transCode, TransCode.withdrawal);
  });

  test('no payee or category recognized leaves both null, not a guess', () {
    final draft = parse('40 euros chez un endroit inconnu');
    expect(draft.payeeId, isNull);
    expect(draft.categoryId, isNull);
  });

  group('account recognition (2026-08-06)', () {
    test('"compte" + a matching name resolves accountId', () {
      final draft = parse('35 euros sur le compte Boursorama chez Carrefour');
      expect(draft.accountId, 30);
      // The payee match must still work normally alongside it - the bug
      // report this fixed was "Boursorama" landing in Tiers *instead* of
      // being recognized as the account, not payee recognition breaking.
      expect(draft.payeeId, 20);
    });

    test('no "compte" word at all leaves accountId null, even if an account '
        'name happens to appear in the sentence', () {
      // Deliberately not matched: without the "compte" gate, a payee that
      // happens to share a word with an account name would silently
      // misfile the transaction onto the wrong account - see
      // parseVoiceTransaction's doc comment.
      final draft = parse('35 euros chez Boursorama');
      expect(draft.accountId, isNull);
    });

    test('"compte" said but no account name matches leaves accountId null, '
        'not a guess', () {
      final draft = parse('35 euros sur le compte de la boulangerie');
      expect(draft.accountId, isNull);
    });

    test('matches "Livret A" too, not just the first account in the list', () {
      final draft = parse('20 euros sur mon compte Livret A');
      expect(draft.accountId, 31);
    });

    test('a distinguishing word breaks the tie between two similarly-named '
        'accounts', () {
      final draft = parse('30 euros sur le compte crédit agricole commun');
      expect(draft.accountId, 32); // "...Compte Commun", not "...Codevi"
    });

    test('two accounts scoring equally (nothing distinguishing mentioned) '
        'leaves accountId null rather than guessing which one', () {
      final draft = parse('30 euros sur le compte crédit agricole');
      expect(draft.accountId, isNull);
    });

    test('a word already claimed by the account match cannot also win the '
        'payee match - reproduces the 2026-08-07 report exactly (a bank '
        'named both a payee, for its own fees, and an account)', () {
      final draft = parse('35 euros chez Carrefour alimentation sur le compte Boursorama');
      expect(draft.accountId, 30); // Boursorama Perso
      expect(draft.payeeId, 20); // Carrefour, not the Boursorama payee
    });
  });
}
