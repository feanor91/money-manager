import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/budget_period.dart' show nextForecastDay;
import '../services/nl_query/answer_formatter.dart';
import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/query_executor.dart';
import '../services/nl_query/query_intent.dart';
import '../services/nl_query/rule_based_query_parser.dart';

const _examples = [
  'Quelles ont été mes dépenses ce mois-ci ?',
  "Combien j'ai dépensé en Alimentation le mois dernier ?",
  'Quel est le solde de mon compte ?',
  'Mes plus grosses dépenses des 3 derniers mois',
  'Revenus et dépenses de cette année',
  'Pourquoi vais-je finir le mois en négatif ?',
  "Mes dépenses en Alimentation par mois depuis le début de l'année",
];

/// A flat "not understood" gives no clue how to rephrase - say what *was*
/// recognized (account, an explicitly-named period) so the user knows the
/// problem is specifically "which kind of question" (dépenses/revenus/
/// solde/...) rather than starting over blind. Deliberately re-derives this
/// from the rule-based parser's own recognizedPieces rather than the local
/// LLM's attempt: this message is only ever shown once *both* have already
/// failed, and the rule-based pieces are the ones a rephrase can actually
/// act on (same fixed keyword set on every platform), unlike whatever the
/// LLM did or didn't parse out of it.
String _notUnderstoodMessage(String question, {required List<Account> accounts}) {
  final pieces = recognizedPieces(question, accounts: accounts);
  final recognized = <String>[
    if (pieces.accountId != null)
      'le compte "${accounts.firstWhere((a) => a.id == pieces.accountId).name}"',
    if (pieces.periodLabel != null) 'la période "${pieces.periodLabel}"',
  ];
  if (recognized.isEmpty) {
    return "Je n'ai pas compris cette question. Essaie une formulation "
        'comme celles ci-dessous.';
  }
  return "J'ai reconnu ${recognized.join(' et ')}, mais pas ce que tu "
      'cherches (dépenses, revenus, solde...) - essaie une formulation '
      'comme celles ci-dessous.';
}

/// Opens the natural-language query tool as a dialog - same shape as
/// [openCategorySpendAnalyzer] (a read-only research tool, not a record
/// editor: dialog, not a bottom sheet, per CLAUDE.md's UI-consistency rule).
/// [defaultAccountId] (e.g. the dashboard's currently selected account) is
/// the fallback account for every question kind that didn't name one
/// itself - by design (2026-08-03), a question is never silently answered
/// "every account combined"; naming an account in the question itself still
/// always wins over this default. [forecastDay] (Settings' "Jour de
/// prévision du solde") is where an unqualified [QueryKind.outlook]
/// question ("pourquoi vais-je finir le mois en négatif") ends its
/// projection - the same day the dashboard's own forecast figures use,
/// not the calendar month's end.
Future<void> openNlQueryDialog({
  required BuildContext context,
  required MmexRepository repo,
  required int forecastDay,
  int? defaultAccountId,
}) {
  final screen = MediaQuery.sizeOf(context);
  final width = screen.width < 760 ? screen.width * 0.95 : 640.0;
  final height = screen.height * 0.8;
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: width,
        height: height,
        child: NlQueryDialog(
          repo: repo,
          defaultAccountId: defaultAccountId,
          forecastDay: forecastDay,
        ),
      ),
    ),
  );
}

class NlQueryDialog extends StatefulWidget {
  final MmexRepository repo;
  final int? defaultAccountId;
  final int forecastDay;

  const NlQueryDialog({
    super.key,
    required this.repo,
    required this.forecastDay,
    this.defaultAccountId,
  });

  @override
  State<NlQueryDialog> createState() => _NlQueryDialogState();
}

class _NlQueryDialogState extends State<NlQueryDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _answer;
  String? _error;
  bool _isAiFreeform = false;

  @override
  void dispose() {
    _controller.dispose();
    // Kills the (Windows-only) llama-server.exe process and frees its
    // multi-gigabyte model from RAM/VRAM the moment this dialog closes,
    // rather than leaving it resident for the rest of the app session - a
    // no-op if local AI was never used this session (see
    // shutdownLocalLlmEngine's own doc comment). Fire-and-forget: dispose()
    // can't be async, and nothing here needs to wait for the process to
    // actually exit.
    shutdownLocalLlmEngine();
    super.dispose();
  }

  /// Also fires for programmatic changes (e.g. the clear button below), not
  /// just typing - so clearing the question by any means brings back the
  /// example chips rather than leaving the last answer/error stuck on screen.
  void _onQuestionChanged(String value) {
    setState(() {
      if (value.isEmpty) {
        _answer = null;
        _error = null;
        _isAiFreeform = false;
      }
    });
  }

  void _clearQuestion() {
    _controller.clear();
    setState(() {
      _answer = null;
      _error = null;
      _isAiFreeform = false;
    });
  }

  Future<void> _ask(String question) async {
    if (question.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _answer = null;
      _error = null;
      _isAiFreeform = false;
    });

    final repo = widget.repo;
    final categories = repo.getCategories(onlyActive: false);
    final accounts = repo.getAccounts();
    final payees = repo.getPayees(onlyActive: false);
    final currency = repo.getBaseCurrency();

    // The (Windows-only, optional) local AI gets first try when it's
    // actually usable; a null intent from it - not enabled, not
    // downloaded, or it genuinely didn't understand - falls straight
    // through to the same rule-based parser used everywhere else, so the
    // feature always answers something rather than erroring out just
    // because local AI happens to be off or unavailable right now.
    var parsed = isLocalLlmSupported
        ? await extractIntentWithLocalLlm(
            question,
            categories: categories,
            accounts: accounts,
            payees: payees,
          )
        : (intent: null, periodWasExplicit: false);
    if (parsed.intent == null) {
      parsed = parseQuestion(
        question,
        categories: categories,
        accounts: accounts,
        payees: payees,
      );
    }
    var intent = parsed.intent;
    if (intent == null) {
      // Neither the intent extractor nor the rule-based parser recognized
      // this as a financial question - rather than a flat rejection, let
      // the same local model answer as ordinary conversation instead (see
      // the badge on the answer container below, which is what keeps this
      // visually distinct from a real computed-from-your-data answer).
      // Only attempted when local AI is actually usable; otherwise there
      // is no model left to ask and the message below is all there is.
      final freeform = isLocalLlmSupported ? await askLocalLlmFreeform(question) : null;
      setState(() {
        _loading = false;
        if (freeform != null) {
          _answer = freeform;
          _isAiFreeform = true;
        } else {
          _error = _notUnderstoodMessage(question, accounts: accounts);
        }
      });
      return;
    }

    // Every question kind - not just "solde" - is scoped to one account: a
    // question that didn't name one itself falls back to the dashboard's
    // currently selected account, or - if there's exactly one account -
    // that one unambiguously. Never guessed when genuinely ambiguous: the
    // user is asked to name one instead.
    if (intent.accountId == null) {
      final fallbackAccountId =
          widget.defaultAccountId ?? (accounts.length == 1 ? accounts.single.id : null);
      if (fallbackAccountId == null) {
        final example = accounts.isNotEmpty ? accounts.first.name : 'Compte Courant';
        setState(() {
          _loading = false;
          _error = 'Précise le compte dans ta question, par exemple : "sur $example".';
        });
        return;
      }
      intent = QueryIntent(
        kind: intent.kind,
        period: intent.period,
        categoryId: intent.categoryId,
        accountId: fallbackAccountId,
        payeeId: intent.payeeId,
        topN: intent.topN,
        asOf: intent.asOf,
      );
    }

    // An unqualified "outlook" question ("pourquoi vais-je finir le mois en
    // négatif") means "d'ici mon prochain jour de prévision", not "d'ici la
    // fin du mois calendaire" - every other kind's period-less default (the
    // current calendar month) doesn't apply here. Naming an explicit period
    // in the question ("... en juillet") still always wins over this.
    if (intent.kind == QueryKind.outlook && !parsed.periodWasExplicit) {
      final today = DateTime.now();
      final forecastDate = nextForecastDay(today, widget.forecastDay);
      intent = QueryIntent(
        kind: intent.kind,
        period: DateRange(
          start: DateTime(today.year, today.month, today.day),
          end: forecastDate.add(const Duration(days: 1)),
          label: 'd\'ici le ${DateFormat('d MMMM yyyy', 'fr_FR').format(forecastDate)}',
        ),
        categoryId: intent.categoryId,
        accountId: intent.accountId,
        payeeId: intent.payeeId,
        topN: intent.topN,
        asOf: intent.asOf,
      );
    }

    try {
      final answer = runQuery(intent, repo);
      final text = formatAnswer(
        intent,
        answer,
        periodWasExplicit: parsed.periodWasExplicit,
        categories: categories,
        accounts: accounts,
        payees: payees,
        currency: currency,
      );
      setState(() {
        _loading = false;
        _answer = text;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Erreur : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // A bare Dialog doesn't reliably pick up the app's dark surface color on
    // its own - paint it explicitly, same fix as category_spend_analyzer.dart.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Poser une question', style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      labelText: 'Ta question',
                      hintText: 'ex : quelles ont été mes dépenses en juillet ?',
                      border: const OutlineInputBorder(),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              tooltip: 'Effacer',
                              onPressed: _clearQuestion,
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: _onQuestionChanged,
                    onSubmitted: _ask,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : () => _ask(_controller.text),
                      icon: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                      label: const Text('Demander'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_answer != null || _error != null)
                    Expanded(
                      child: SingleChildScrollView(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _error != null
                                ? Theme.of(context).colorScheme.errorContainer
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // A computed answer comes straight from the
                              // database and is always exact; this badge is
                              // what tells them apart at a glance, since a
                              // free-form one is the model improvising, not
                              // a real figure from their data (see CLAUDE.md
                              // - a financial figure must never look like it
                              // could be an invention of the model).
                              if (_isAiFreeform)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.auto_awesome,
                                        size: 14,
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        "Réponse libre de l'IA, pas un calcul sur tes données",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Theme.of(context).colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Text(_error ?? _answer ?? ''),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Exemples :', style: Theme.of(context).textTheme.labelLarge),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final example in _examples)
                                  ActionChip(
                                    label: Text(example),
                                    onPressed: _loading
                                        ? null
                                        : () {
                                            _controller.text = example;
                                            _ask(example);
                                          },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
