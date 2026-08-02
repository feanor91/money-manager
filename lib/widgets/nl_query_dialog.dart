import 'package:flutter/material.dart';

import '../data/mmex_repository.dart';
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
];

/// Opens the natural-language query tool as a dialog - same shape as
/// [openCategorySpendAnalyzer] (a read-only research tool, not a record
/// editor: dialog, not a bottom sheet, per CLAUDE.md's UI-consistency rule).
/// [defaultAccountId] is only used as a fallback when a "solde" question
/// doesn't name an account itself (e.g. the dashboard's currently selected
/// account) - never silently applied to expense/income totals, which stay
/// "every account combined" unless the question actually names one.
Future<void> openNlQueryDialog({
  required BuildContext context,
  required MmexRepository repo,
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
        child: NlQueryDialog(repo: repo, defaultAccountId: defaultAccountId),
      ),
    ),
  );
}

class NlQueryDialog extends StatefulWidget {
  final MmexRepository repo;
  final int? defaultAccountId;

  const NlQueryDialog({super.key, required this.repo, this.defaultAccountId});

  @override
  State<NlQueryDialog> createState() => _NlQueryDialogState();
}

class _NlQueryDialogState extends State<NlQueryDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _answer;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    if (question.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _answer = null;
      _error = null;
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
      setState(() {
        _loading = false;
        _error = "Je n'ai pas compris cette question. Essaie une "
            'formulation comme celles ci-dessous.';
      });
      return;
    }

    // A "solde" question that didn't name an account itself falls back to
    // the dashboard's currently selected account, or - if there's exactly
    // one account - that one unambiguously. Never guessed when genuinely
    // ambiguous: the user is asked to name one instead.
    if (intent.kind == QueryKind.balance && intent.accountId == null) {
      final fallbackAccountId =
          widget.defaultAccountId ?? (accounts.length == 1 ? accounts.single.id : null);
      if (fallbackAccountId == null) {
        final example = accounts.isNotEmpty ? accounts.first.name : 'Compte Courant';
        setState(() {
          _loading = false;
          _error = 'Précise le compte, par exemple : "quel est le solde de $example ?"';
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
                    decoration: const InputDecoration(
                      labelText: 'Ta question',
                      hintText: 'ex : quelles ont été mes dépenses en juillet ?',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.search,
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
                          child: Text(_error ?? _answer ?? ''),
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
