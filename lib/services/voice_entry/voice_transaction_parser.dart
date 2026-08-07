import '../../models/account.dart';
import '../../models/category.dart';
import '../../models/payee.dart';
import '../../models/transaction.dart';
import '../../utils/list_utils.dart';
import '../nl_query/name_matcher.dart';

/// Everything a spoken transcript could tell us about a transaction, meant
/// to seed TransactionEditorSheet's fields - never inserted directly. The
/// user always sees and can correct every field in that same sheet before
/// hitting Enregistrer, so a wrong guess here costs a tap to fix, not a bad
/// transaction silently saved.
class VoiceTransactionDraft {
  final double? amount;
  final DateTime date;
  final TransCode transCode;
  final int? categoryId;
  final int? payeeId;

  /// Null means "leave the default account untouched" (the one the "+"
  /// button was pressed from) - only ever set when the transcript actually
  /// named a compte (see [parseVoiceTransaction]'s "compte" gate).
  final int? accountId;

  /// Only set when [amount] couldn't be found - the raw transcript, so
  /// nothing spoken is silently lost even when parsing fails on the one
  /// field that can't reasonably be left for a dropdown to default.
  final String? notes;

  const VoiceTransactionDraft({
    required this.amount,
    required this.date,
    required this.transCode,
    this.categoryId,
    this.payeeId,
    this.accountId,
    this.notes,
  });
}

// Folded (foldDiacritics'd) keywords only - deliberately narrow and
// unambiguous. "vire"/"versement" are left out on purpose: in MMEX terms
// those often mean a transfer between the user's own accounts (a second
// account to resolve, out of scope for voice entry - see
// voice_transaction_sheet.dart's doc comment), not income from outside, and
// misreading one as a plain deposit would be a real error, not just a
// cosmetic default. "paye"/"payer" (in any conjugated form containing that
// root) are left out for the same reason, even though it's the intuitive
// word for "I got paid" - added 2026-08-06: everyday French uses "payé"
// at least as often, likely more, for an *expense* ("j'ai payé mon loyer",
// "payé les courses") - matching it unconditionally to income would trade
// today's under-recognition (a tap to fix) for silently mis-flagging
// expenses as income instead, a worse failure in the other direction.
const _incomeKeywords = ['recu', 'salaire', 'remboursement', 'encaisse', 'prime', 'revenu'];

/// Parses an already speech-recognized French transcript (not raw audio)
/// into a [VoiceTransactionDraft]. [payees]/[categories] should be the same
/// lists already loaded for the current database (as passed to
/// TransactionEditorSheet), so matching only ever resolves against real,
/// existing entries - see [bestNameMatch].
///
/// Amount extraction only recognizes digits ("35 euros"/"35€"), not spelled-
/// out numbers ("trente-cinq euros") - Android's on-device recognizer
/// normally transcribes a dictated number as digits already, so this is
/// expected to cover the common case without a whole French number-word
/// parser. Confirm this holds on a real device; if the recognizer ever
/// hands back word-form numbers instead, [_extractAmount] is the one place
/// that would need to grow that support.
VoiceTransactionDraft parseVoiceTransaction(
  String transcript, {
  required List<Payee> payees,
  required List<Category> categories,
  required List<Account> accounts,
  DateTime? now,
}) {
  final text = foldDiacritics(transcript);
  final today = _dateOnly(now ?? DateTime.now());

  final amount = _extractAmount(text);
  final date = _extractDate(text, today);
  final transCode = _extractTransCode(text);

  // Only attempted when "compte" is actually said - found 2026-08-06:
  // matching account names unconditionally against the whole transcript is
  // too easy to confuse with a similarly-named payee ("sur le compte
  // Boursorama" needs to win over a "Boursorama" payee that may also
  // exist, exactly what happened without this gate - the account was
  // never touched and "Boursorama" landed in Tiers instead). Word-overlap,
  // not bestNameMatch's exact whole-name match - found the same day that
  // real account names are routinely multi-word ("Boursorama perso",
  // "Crédit Agricole compte commun"), which nobody says in full out loud.
  final accountId = RegExp(r'\bcompte\b').hasMatch(text)
      ? _bestAccountWordMatch(text, accounts)
      : null;
  // Computed *before* payee/category matching, and its own words scrubbed
  // out of the text those use - found 2026-08-07: with the account fix
  // above now correctly recognizing "compte Boursorama", the *payee* match
  // then separately picked "Boursorama" over the actually-said "chez
  // Carrefour" anyway (bestNameMatch prefers the longer of several
  // candidates that all appear somewhere in the text, with no idea the
  // account match had already claimed that word for a different purpose).
  final matchedAccount = findById(accounts, accountId, (a) => a.id);
  final textForOtherFields =
      matchedAccount == null ? text : _stripWords(text, _significantWords(matchedAccount.name));

  final payeeId =
      bestNameMatch(textForOtherFields, payees.map((p) => MapEntry(p.id, p.name)));
  final categoryFromText =
      bestNameMatch(textForOtherFields, categories.map((c) => MapEntry(c.id, c.name)));
  final matchedPayee = findById(payees, payeeId, (p) => p.id);
  // An explicit category word in the transcript wins over the payee's own
  // default - the spoken word is more specific to *this* transaction than
  // whatever category that payee usually falls under.
  final categoryId = categoryFromText ?? matchedPayee?.categoryId;

  return VoiceTransactionDraft(
    amount: amount,
    date: date,
    transCode: transCode,
    categoryId: categoryId,
    payeeId: payeeId,
    accountId: accountId,
    notes: amount == null ? transcript : null,
  );
}

// Excluded from account-name scoring below: "compte" is the gate word
// itself (already guaranteed present) and would otherwise favor every
// account whose own name happens to contain it too ("Crédit Agricole
// *compte* commun") without actually distinguishing anything; the rest are
// French articles/possessives too generic to mean anything on their own.
const _accountStopWords = {'compte', 'de', 'du', 'des', 'la', 'le', 'les', 'mon', 'ma', 'mes'};

/// [name]'s own words worth matching on - folded, split on anything that
/// isn't a letter/digit, short filler words and [_accountStopWords]
/// dropped. Shared by [_bestAccountWordMatch]'s scoring and
/// [parseVoiceTransaction]'s scrubbing of an already-matched account's name
/// out of the text before payee/category matching runs.
Iterable<String> _significantWords(String name) => foldDiacritics(name)
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.length >= 3 && !_accountStopWords.contains(w));

/// Replaces every whole-word occurrence of any of [words] in [text] with a
/// space, so a word already claimed by one field's match (e.g. an account
/// name) can't also satisfy a different field's match afterwards.
String _stripWords(String text, Iterable<String> words) {
  var result = text;
  for (final word in words) {
    result = result.replaceAll(RegExp('\\b$word\\b'), ' ');
  }
  return result;
}

/// Which account best matches [text], by how many of *that account's own*
/// significant words (see [_significantWords]) show up as whole words in
/// [text] - not [bestNameMatch]'s exact whole-name match, which real
/// multi-word account names ("Boursorama perso") essentially never satisfy
/// from natural speech. Returns null - never a guess - when the best score
/// is shared by more than one account (e.g. "compte crédit agricole" alone,
/// with both a "...compte commun" and a "...CODEVI" account, neither
/// mentioned specifically enough to break the tie).
int? _bestAccountWordMatch(String text, List<Account> accounts) {
  var bestScore = 0;
  int? bestId;
  var tie = false;
  for (final account in accounts) {
    var score = 0;
    for (final word in _significantWords(account.name)) {
      if (RegExp('\\b$word\\b').hasMatch(text)) score++;
    }
    if (score == 0) continue;
    if (score > bestScore) {
      bestScore = score;
      bestId = account.id;
      tie = false;
    } else if (score == bestScore) {
      tie = true;
    }
  }
  return tie ? null : bestId;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

double? _extractAmount(String text) {
  // A number immediately followed by "euro(s)"/"€" wins over any other
  // number in the sentence - otherwise a spoken day-of-month ("le 15
  // janvier") could get mistaken for the amount.
  final withCurrency =
      RegExp(r'(\d+(?:[.,]\d{1,2})?)\s*(?:€|euros?)\b').firstMatch(text);
  final match = withCurrency ?? RegExp(r'\b(\d+(?:[.,]\d{1,2})?)\b').firstMatch(text);
  if (match == null) return null;
  return double.tryParse(match.group(1)!.replaceAll(',', '.'));
}

DateTime _extractDate(String text, DateTime today) {
  if (RegExp(r'avant.?hier').hasMatch(text)) {
    return today.subtract(const Duration(days: 2));
  }
  if (RegExp(r'\bhier\b').hasMatch(text)) {
    return today.subtract(const Duration(days: 1));
  }
  // "aujourd'hui" and anything unrecognized both default to today - a
  // transaction just entered by voice is overwhelmingly likely to be
  // today's, and the date field is a single tap to correct otherwise.
  return today;
}

TransCode _extractTransCode(String text) {
  for (final keyword in _incomeKeywords) {
    if (RegExp('\\b$keyword').hasMatch(text)) return TransCode.deposit;
  }
  return TransCode.withdrawal;
}
