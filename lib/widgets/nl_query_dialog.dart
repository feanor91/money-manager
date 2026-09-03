import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../data/mmex_repository.dart';
import '../models/account.dart';
import '../models/budget_period.dart' show nextForecastDay;
import '../services/nl_query/answer_formatter.dart';
import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/query_executor.dart';
import '../services/nl_query/query_intent.dart';
import '../services/nl_query/rule_based_query_parser.dart';

/// Same one-line platform-check convention as dashboard_screen.dart/
/// transactions_screen.dart - see below for why this matters here too.
bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

const _examples = [
  'Quelles ont été mes dépenses ce mois-ci ?',
  "Combien j'ai dépensé en Alimentation le mois dernier ?",
  'Quel est le solde de mon compte ?',
  'Mes plus grosses dépenses des 3 derniers mois',
  'Revenus et dépenses de cette année',
  'Pourquoi vais-je finir le mois en négatif ?',
  'Analyse complète de mes dépenses "Vacances" sur les 3 dernières années',
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
String _notUnderstoodMessage(String question,
    {required List<Account> accounts}) {
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

/// What kind of answer a [_ChatEntry] holds - drives both the little badge
/// shown above it and whether it's rendered as Markdown (see
/// [_NlQueryDialogState._buildEntryText]).
enum _AnswerKind {
  /// The deterministic formatter (answer_formatter.dart) - always exact,
  /// no badge.
  computed,

  /// The model answering as plain conversation - not grounded in the
  /// user's real data at all (see the badge's own wording).
  freeform,

  /// The model wrote and ran real SQL against the user's data, then
  /// phrased the answer from the actual result rows - grounded, but the
  /// model's own phrasing rather than answer_formatter.dart's.
  sqlGrounded,

  /// A genuine failure (network/database error) or "not understood".
  error,
}

/// One line of the chat transcript - either the user's own question, or
/// this app's answer to it (computed, freeform, SQL-grounded, or an
/// error/"not understood" message - see [_AnswerKind]).
class _ChatEntry {
  final bool isUser;
  final String text;
  final _AnswerKind kind;

  /// The raw rows behind a [_AnswerKind.sqlGrounded] answer, as CSV -
  /// null for every other kind (2026-08-27 user request: an export button
  /// on SQL-grounded answers so the real numbers can go into a
  /// spreadsheet, not just the model's prose).
  final String? csv;

  /// Real generation throughput for a [_AnswerKind.freeform]/[sqlGrounded]
  /// answer (2026-08-31 user request) - null whenever the backend's own
  /// response didn't report a real generated-token count (see
  /// LlmResponse's own doc comment) or for any other answer kind
  /// (computed/error have no model generation to measure at all) - never
  /// estimated from elapsed time alone.
  final double? tokensPerSecond;

  const _ChatEntry.user(this.text)
      : isUser = true,
        kind = _AnswerKind.computed,
        csv = null,
        tokensPerSecond = null;

  const _ChatEntry.assistant(this.text, this.kind,
      {this.csv, this.tokensPerSecond})
      : isUser = false;
}

/// Opens the natural-language query tool as a dialog - same shape as
/// [openCategorySpendAnalyzer] (a read-only research tool, not a record
/// editor: dialog, not a bottom sheet, per CLAUDE.md's UI-consistency rule).
/// Sized close to fullscreen (2026-08-23 user request: "je veux que tu
/// ouvres complètement le système d'IA" - a proper chat needs real room for
/// a growing transcript and long, exhaustive answers, not a small fixed
/// box). [defaultAccountId] (e.g. the dashboard's currently selected
/// account) is the fallback account for every question kind that didn't
/// name one itself - by design (2026-08-03), a question is never silently
/// answered "every account combined"; naming an account in the question
/// itself still always wins over this default. [forecastDay] (Settings'
/// "Jour de prévision du solde") is where an unqualified
/// [QueryKind.outlook] question ("pourquoi vais-je finir le mois en
/// négatif") ends its projection - the same day the dashboard's own
/// forecast figures use, not the calendar month's end.
Future<void> openNlQueryDialog({
  required BuildContext context,
  required MmexRepository repo,
  required int forecastDay,
  int? defaultAccountId,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      // The width/height used to be computed once, outside this builder,
      // from the *caller's* MediaQuery at the moment the dialog opened -
      // frozen for the dialog's whole lifetime, never revisited afterwards.
      // 2026-09-02 user report on Android: opening it in portrait then
      // rotating to landscape left it stuck at the portrait size (and vice
      // versa) - rotating a *second* time, back to the orientation it was
      // opened in, only ever looked "fixed" because the frozen size
      // happened to match the screen again by coincidence, not because
      // anything had actually re-adjusted. A [Builder] (rather than
      // computing this outside the widget tree) reads MediaQuery from
      // *inside* its own build() method, so Flutter re-runs it - recomputing
      // width/height - every time the ambient MediaQuery actually changes,
      // for as long as the dialog stays open, not just at the instant it
      // was first built.
      child: Builder(
        builder: (context) {
          final screen = MediaQuery.sizeOf(context);
          final width = screen.width < 760 ? screen.width * 0.97 : screen.width * 0.9;
          final height = screen.height * 0.92;
          return SizedBox(
            width: width,
            height: height,
            child: NlQueryDialog(
              repo: repo,
              defaultAccountId: defaultAccountId,
              forecastDay: forecastDay,
            ),
          );
        },
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
  final _questionFocusNode = FocusNode();
  final _scrollController = ScrollController();
  bool _loading = false;
  final List<_ChatEntry> _messages = [];

  /// Bumped at the start of every [_ask] call and by [_cancelAsk] - see
  /// [_ask]'s own `reply` closure, which discards a response if this no
  /// longer matches the generation it captured when it started.
  int _requestGeneration = 0;

  /// Shown next to the dialog's title (2026-08-31 user request) - see
  /// currentLlmModelLabel's own doc comment for when this stays null
  /// (AI disabled, or "Mon PC" mode with no nameable model).
  String? _modelLabel;

  @override
  void initState() {
    super.initState();
    if (isLocalLlmSupported) {
      currentLlmModelLabel().then((label) {
        if (!mounted) return;
        setState(() => _modelLabel = label);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _questionFocusNode.dispose();
    _scrollController.dispose();
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

  void _scrollToBottom() {
    // A frame needs to actually pass (the new message just got added to
    // the list) before there's anything new to scroll to - jumping inside
    // the same setState call would still see the old scroll extent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Every prior question/answer pair already in the transcript, oldest
  /// first - handed to the SQL-chat engine (sql_query_engine.dart's
  /// ChatTurn) so a follow-up question ("et l'an dernier ?") can be
  /// resolved against what was just discussed. Pairs a user entry with
  /// whatever assistant entry immediately follows it, regardless of that
  /// answer's own kind (computed/freeform/SQL-grounded) - a follow-up can
  /// just as reasonably refer back to an exact computed answer as to an
  /// AI one.
  List<ChatTurn> get _history {
    final turns = <ChatTurn>[];
    for (var i = 0; i < _messages.length - 1; i++) {
      final entry = _messages[i];
      final next = _messages[i + 1];
      if (entry.isUser && !next.isUser) {
        turns.add(ChatTurn(question: entry.text, answer: next.text));
      }
    }
    return turns;
  }

  void _clearConversation() {
    _controller.clear();
    setState(() => _messages.clear());
  }

  /// Puts a previously-asked question back into the input field for editing
  /// (2026-08-24 user request: "reprendre une question déjà posée pour la
  /// modifier ou la préciser") - tapping any of the user's own bubbles in
  /// the transcript, rather than retyping a long question from scratch to
  /// fix a typo or add detail. Does not re-ask it or touch the transcript;
  /// the user still presses send.
  void _editQuestion(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _questionFocusNode.requestFocus();
  }

  /// Saves a SQL-grounded answer's raw rows to a .csv file via the same
  /// cross-platform save dialog `FilePicker.saveFile` already handles for
  /// the database export in settings_screen.dart (web: browser download,
  /// desktop: native save dialog, Android: share/save sheet) - reused
  /// rather than building a separate platform-shell just for this.
  Future<void> _exportCsv(BuildContext context, String csv) async {
    final timestamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    try {
      await FilePicker.saveFile(
        fileName: 'reponse_ia_$timestamp.csv',
        // A UTF-8 BOM (2026-08-27 user report on the transactions ledger's
        // own CSV export, same underlying issue here) - Excel does not
        // auto-detect plain UTF-8 without one and falls back to the
        // system's ANSI code page, mangling accented characters on open.
        bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Échec de l'export CSV : $e")),
      );
    }
  }

  /// Copies a whole answer's plain text to the clipboard (2026-08-27 user
  /// request: "pouvoir copier la totalité du texte de la réponse... pour
  /// un copier/coller dans un notepad") - a one-tap alternative to
  /// manually drag-selecting the whole bubble.
  Future<void> _copyAnswer(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Réponse copiée.'), duration: Duration(seconds: 2)),
    );
  }

  /// "Interrompre" (2026-08-31 user request) - invalidates the in-flight
  /// [_ask] call (see [_requestGeneration]/its `reply` closure) so its
  /// answer, whenever it eventually arrives, is silently dropped instead of
  /// popping into the transcript after the user has moved on, and resets
  /// the UI to ready-for-input immediately.
  ///
  /// This can only ever be a *client-side* cancel: every backend here
  /// (LlamaServerClient/CloudLlmClient) sends `stream: false`, so the
  /// server has already generated the *entire* answer before any of it
  /// reaches this app - there is no partial response to truncate, and
  /// closing the connection can't make already-spent server-side
  /// compute/cost un-happen. The one case where this genuinely stops real
  /// work is the desktop build's own spawned local `llama-server.exe`:
  /// [shutdownLocalLlmEngine] kills that process outright, which does
  /// immediately free the CPU/GPU it was using - worth doing regardless of
  /// backend, since it's a no-op everywhere else and the next question
  /// simply pays a fresh engine's startup cost instead.
  void _cancelAsk() {
    _requestGeneration++;
    setState(() => _loading = false);
    shutdownLocalLlmEngine();
  }

  Future<void> _ask(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || _loading) return;
    final history = _history; // captured before this turn's own question
    // Bumped again by _cancelAsk (or a fresh _ask call) - reply() below
    // checks this before ever touching state, so a response that arrives
    // after the user interrupted/moved on is silently discarded instead of
    // popping up out of nowhere.
    final myGeneration = ++_requestGeneration;
    _controller.clear();
    setState(() {
      _loading = true;
      _messages.add(_ChatEntry.user(trimmed));
    });
    _scrollToBottom();

    void reply(String text, _AnswerKind kind,
        {String? csv, double? tokensPerSecond}) {
      if (myGeneration != _requestGeneration) return;
      setState(() {
        _loading = false;
        _messages.add(_ChatEntry.assistant(text, kind,
            csv: csv, tokensPerSecond: tokensPerSecond));
      });
      _scrollToBottom();
    }

    final repo = widget.repo;
    final categories = repo.getCategories(onlyActive: false);
    final accounts = repo.getAccounts();
    final payees = repo.getPayees(onlyActive: false);
    final currency = repo.getBaseCurrency();

    // 2026-09-03 user request ("je veux que la question parte
    // immédiatement vers [l'IA], pas de routage redéfini... seul l'IA doit
    // me répondre") - once AI is switched on in Settings
    // (isLocalLlmEnabled()), it answers *every* question directly via the
    // full-database-access engine, full stop. Previously a question always
    // went through extractIntentWithLocalLlm's closed intent vocabulary
    // first, and - if that call declined *and* full SQL access also
    // declined - silently fell through to the pure-regex rule-based parser
    // (rule_based_query_parser.dart) and its fuzzy name matching
    // (name_matcher.dart matching any word against real account/category/
    // payee names). Both are keyword-matching, not understanding: a rich,
    // clearly-open-ended question could get silently hijacked by a single
    // incidental word ("opérations" reads as a plain expense filter,
    // "factures" matches a real category by name) with no indication that
    // this happened, and no relation to the multi-step AI answer the user
    // actually wanted (2026-09-03 user reports: "opérations récurrentes"
    // and "factures" mentioned in an analytical question both silently
    // routed there). The deterministic engine below - both the intent
    // extractor and the rule-based parser - now runs ONLY when AI is off,
    // never as an under-the-hood fallback out from under an AI answer that
    // declined; a declined AI question instead falls to the same model
    // answering as free conversation (still AI, still disclaimed via its
    // own badge), never to the closed engine.
    if (isLocalLlmSupported && await isLocalLlmEnabled()) {
      // dbPath (desktop: the real file path, reopened read-only by the
      // implementation) vs repo (web and Android: the in-memory database
      // itself - there is no file to reopen there, see
      // local_llm_manager_web.dart/local_llm_manager_io.dart's Android
      // branch).
      final sqlOutcome = kIsWeb || _isAndroidPlatform
          ? await askLocalLlmWithFullDataAccess(trimmed,
              repo: repo, history: history)
          : await askLocalLlmWithFullDataAccess(trimmed,
              dbPath: repo.db.label, history: history);
      switch (sqlOutcome) {
        case SqlAccessSuccess(:final answer):
          reply(answer.text, _AnswerKind.sqlGrounded,
              csv: answer.csv, tokensPerSecond: answer.tokensPerSecond);
          return;
        case SqlAccessError(:final message):
          // Told apart from "not understood" on purpose (same 2026-08-31
          // lesson as askLocalLlmFreeform's own error case below) - a real
          // backend failure (wrong model id, rate limit, an invalid query)
          // must never look like a wrong/misleading fallback answer.
          reply(
              "Le service IA a renvoyé une erreur ($message). Réessaie dans "
              'quelques instants, ou vérifie les paramètres IA.',
              _AnswerKind.error);
          return;
        case SqlAccessUnavailable():
        // The model itself declined this question against the schema (or
        // its response wasn't usable) - falls to plain AI conversation
        // just below, never to the closed deterministic engine.
      }
      final freeform = await askLocalLlmFreeform(trimmed, history: history);
      switch (freeform) {
        case LlmFreeformSuccess(:final text, :final tokensPerSecond):
          reply(text, _AnswerKind.freeform, tokensPerSecond: tokensPerSecond);
        case LlmFreeformError(:final message):
          reply(
              "Le service IA a renvoyé une erreur ($message). Réessaie dans "
              'quelques instants, ou vérifie les paramètres IA.',
              _AnswerKind.error);
        case LlmFreeformUnavailable():
          reply(
              "L'IA n'a pas réussi à répondre à cette question à partir de "
              'tes données. Essaie de la reformuler.',
              _AnswerKind.error);
      }
      return;
    }

    // AI off (or unsupported on this platform) - the same closed
    // rule-based engine as always, unchanged.
    final parsed = parseQuestion(
      trimmed,
      categories: categories,
      accounts: accounts,
      payees: payees,
    );
    var intent = parsed.intent;
    if (intent == null) {
      reply(_notUnderstoodMessage(trimmed, accounts: accounts),
          _AnswerKind.error);
      return;
    }

    // Every question kind - not just "solde" - is scoped to one account: a
    // question that didn't name one itself falls back to the dashboard's
    // currently selected account, or - if there's exactly one account -
    // that one unambiguously. Never guessed when genuinely ambiguous: the
    // user is asked to name one instead.
    //
    // One deliberate exception: a QueryKind.adHoc question grouped by
    // account ("mes dépenses par compte") is specifically about comparing
    // every account - forcing it down to one first would make that grouping
    // pointless. Confirmed explicitly as the one case allowed to break the
    // "never silently combine accounts" rule below.
    final wantsEveryAccount = intent.kind == QueryKind.adHoc &&
        intent.adHocGroupBy == AdHocGroupBy.account;
    if (intent.accountId == null && !wantsEveryAccount) {
      final fallbackAccountId = widget.defaultAccountId ??
          (accounts.length == 1 ? accounts.single.id : null);
      if (fallbackAccountId == null) {
        final example =
            accounts.isNotEmpty ? accounts.first.name : 'Compte Courant';
        reply(
            'Précise le compte dans ta question, par exemple : "sur $example".',
            _AnswerKind.error);
        return;
      }
      intent = intent.copyWith(accountId: fallbackAccountId);
    }

    // An unqualified "outlook" question ("pourquoi vais-je finir le mois en
    // négatif") means "d'ici mon prochain jour de prévision", not "d'ici la
    // fin du mois calendaire" - every other kind's period-less default (the
    // current calendar month) doesn't apply here. Naming an explicit period
    // in the question ("... en juillet") still always wins over this.
    if (intent.kind == QueryKind.outlook && !parsed.periodWasExplicit) {
      final today = DateTime.now();
      final forecastDate = nextForecastDay(today, widget.forecastDay);
      intent = intent.copyWith(
        period: DateRange(
          start: DateTime(today.year, today.month, today.day),
          end: forecastDate.add(const Duration(days: 1)),
          label:
              'd\'ici le ${DateFormat('d MMMM yyyy', 'fr_FR').format(forecastDate)}',
        ),
      );
    }

    try {
      // QueryKind.adHoc runs straight against the ordinary repo like every
      // other kind - ad_hoc_query.dart's buildAdHocSql only ever emits a
      // parameterized SELECT built from a closed Dart switch over typed
      // enums (see its own doc comment), never free text a model wrote, so
      // there is nothing here for a dedicated read-only connection to
      // actually guard against. A prior version of this code reopened the
      // database via openReadOnlyAdHocRepository for this one kind as
      // "defense in depth" - harmless on desktop, but that function is
      // Windows-only (see local_llm_manager_io.dart), so on web/Android it
      // always returned null and every adHoc question (e.g. "mes revenus
      // mois par mois", which the rule-based parser maps to this kind) hit
      // "impossible d'accéder à la base en lecture seule" unconditionally -
      // found 2026-09-01 from a real user report on both platforms.
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
      reply(text, _AnswerKind.computed);
    } catch (e) {
      reply('Erreur : $e', _AnswerKind.error);
    }
  }

  // The AI-answered text (both the free-form and the SQL-grounded modes)
  // is Markdown on purpose: report mode (see sql_query_engine.dart's
  // buildAnswerFormattingPrompt) asks the model for sections, bullets and
  // bold headings, which would be an unreadable wall of plain text if
  // rendered as a single [Text]. Computed (deterministic formatter)
  // answers and errors are plain text and are left as-is.
  Widget _buildEntryText(BuildContext context, _ChatEntry entry) {
    if (entry.kind != _AnswerKind.freeform &&
        entry.kind != _AnswerKind.sqlGrounded) {
      return Text(entry.text);
    }
    return MarkdownBody(
      data: entry.text,
      styleSheet: MarkdownStyleSheet(
        p: Theme.of(context).textTheme.bodyMedium,
        strong: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
      selectable: true,
    );
  }

  Widget _buildBubble(BuildContext context, _ChatEntry entry) {
    final theme = Theme.of(context);
    if (entry.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _loading ? null : () => _editQuestion(entry.text),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Tooltip(
                    message: 'Toucher pour reprendre cette question',
                    child: Text(entry.text, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final isError = entry.kind == _AnswerKind.error;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isError
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A computed answer comes straight from the database and is
              // always exact; this badge is what tells the other two kinds
              // apart at a glance (see CLAUDE.md - a financial figure must
              // never look like it could be an invention of the model).
              if (entry.kind == _AnswerKind.freeform)
                const _AnswerBadge(
                  icon: Icons.auto_awesome,
                  label: "Réponse libre de l'IA, pas un calcul sur tes données",
                ),
              if (entry.kind == _AnswerKind.sqlGrounded)
                const _AnswerBadge(
                  icon: Icons.travel_explore,
                  label:
                      "Réponse IA à partir d'une requête sur tes données réelles",
                ),
              _buildEntryText(context, entry),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                children: [
                  // Copy-the-whole-answer (2026-08-27 user request: "pouvoir
                  // copier la totalité du texte... pour un copier/coller
                  // dans un notepad") - on every assistant bubble, not just
                  // SQL-grounded ones, since even a computed/freeform answer
                  // is worth pasting elsewhere. A convenience shortcut for
                  // "select everything in this bubble", not a substitute
                  // for it - the bubble's own text is still selectable
                  // directly (see this dialog's own SelectionArea).
                  TextButton.icon(
                    onPressed: () => _copyAnswer(context, entry.text),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copier'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  if (entry.csv != null)
                    TextButton.icon(
                      onPressed: () => _exportCsv(context, entry.csv!),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Exporter en CSV'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
              if (entry.tokensPerSecond != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${entry.tokensPerSecond!.toStringAsFixed(1)} tokens/s',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A bare Dialog doesn't reliably pick up the app's dark surface color on
    // its own - paint it explicitly, same fix as category_spend_analyzer.dart.
    //
    // Its own SelectionArea (2026-08-24 user report: "je ne peux toujours
    // pas faire de copie") - the app-wide one wrapping _PinGate's main route
    // (app.dart) doesn't reach here: showDialog pushes this dialog as a
    // *separate* route/OverlayEntry on the same Navigator, a sibling branch
    // of the widget tree rather than a descendant of that route's content,
    // so SelectionArea (which propagates via the widget tree, not shared
    // Overlay/Navigator membership) needs its own instance in every such
    // route to make its own text selectable.
    return SelectionArea(
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: 'Discuter avec mes finances',
                        style: Theme.of(context).textTheme.titleLarge,
                        children: _modelLabel == null
                            ? null
                            : [
                                TextSpan(
                                  text: ' ($_modelLabel)',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outline),
                                ),
                              ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_messages.isNotEmpty)
                    IconButton(
                      tooltip: 'Nouvelle conversation',
                      icon: const Icon(Icons.refresh),
                      onPressed: _loading ? null : _clearConversation,
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
              child: _messages.isEmpty
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Exemples :',
                              style: Theme.of(context).textTheme.labelLarge),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final example in _examples)
                                ActionChip(
                                  label: Text(example),
                                  onPressed:
                                      _loading ? null : () => _ask(example),
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(20),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) =>
                          _buildBubble(context, _messages[index]),
                    ),
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Réflexion en cours...',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    TextButton.icon(
                      onPressed: _cancelAsk,
                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                      label: const Text('Interrompre'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _questionFocusNode,
                      decoration: const InputDecoration(
                        labelText: 'Ta question',
                        hintText:
                            'ex : quelles ont été mes dépenses en juillet ?',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      enabled: !_loading,
                      onSubmitted: _ask,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('nlQuerySendButton'),
                    onPressed: _loading ? null : () => _ask(_controller.text),
                    icon: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnswerBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _AnswerBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
