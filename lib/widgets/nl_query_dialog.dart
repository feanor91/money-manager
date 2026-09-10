import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'package:money_manager_core/data/mmex_repository.dart';
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/budget_period.dart' show nextForecastDay;
import '../services/nl_query/answer_formatter.dart';
import '../services/nl_query/local_llm/local_llm_manager.dart';
import '../services/nl_query/local_llm/local_llm_support.dart';
import '../services/nl_query/query_executor.dart';
import '../services/nl_query/query_intent.dart';
import '../services/nl_query/rule_based_query_parser.dart';
import '../screens/pin_lock_screen.dart' show PinUnlockForm;
import '../state/pin_lock_provider.dart';
import 'answer_pdf.dart';

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

  /// A live, in-progress step of the model actually working (2026-09-10
  /// user request: "afficher en temps réel... ce que fait le modèle", like
  /// a standard AI chat's own "thinking" panel) - [_ChatEntry.phaseLabel]
  /// names which step ("Écriture de la requête", "Formulation de la
  /// réponse"...), [_ChatEntry.text] grows live as chunks arrive (see
  /// [LlmChunkCallback]/[SqlAccessProgressCallback]), and
  /// [_ChatEntry.isDone] flips true once that step finishes. Left in the
  /// transcript afterwards (collapsed by the user if they choose to, not
  /// removed) as a record of what actually happened - the real, final
  /// answer still gets its own normal bubble appended after every step's
  /// thinking entry.
  thinking,
}

/// One line of the chat transcript - either the user's own question, or
/// this app's answer to it (computed, freeform, SQL-grounded, an
/// error/"not understood" message, or a live in-progress thinking step -
/// see [_AnswerKind]). Mutable (not the immutable value type this looked
/// like before [_AnswerKind.thinking] existed) so a thinking entry already
/// in [_NlQueryDialogState._messages] can grow in place as chunks stream
/// in, rather than needing a fresh list entry (and losing scroll position)
/// on every single token.
class _ChatEntry {
  final bool isUser;
  String text;
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

  /// See [LlmResponse]'s own doc comment on both (2026-09-10 user request:
  /// "ajouter le nombre de token généré en différentiant thinking et
  /// réponse") - [completionTokens] is the total, [reasoningTokens] the
  /// portion of it spent on hidden reasoning before the real answer, only
  /// ever non-null when the backend actually reports that split. Neither
  /// is ever estimated - same "jamais de chiffre inventé" rule as
  /// [tokensPerSecond].
  final int? completionTokens;
  final int? reasoningTokens;

  /// Only set for [_AnswerKind.thinking] - which step this is ("Écriture
  /// de la requête"...), shown as the entry's own title.
  final String? phaseLabel;

  /// Only meaningful for [_AnswerKind.thinking] - true once this step's
  /// call has actually finished (success or failure alike), false while
  /// still streaming. Drives the small spinner next to [phaseLabel].
  bool isDone;

  _ChatEntry.user(this.text)
      : isUser = true,
        kind = _AnswerKind.computed,
        csv = null,
        tokensPerSecond = null,
        completionTokens = null,
        reasoningTokens = null,
        phaseLabel = null,
        isDone = true;

  _ChatEntry.assistant(this.text, this.kind,
      {this.csv, this.tokensPerSecond, this.completionTokens, this.reasoningTokens})
      : isUser = false,
        phaseLabel = null,
        isDone = true;

  _ChatEntry.thinking(this.phaseLabel)
      : isUser = false,
        text = '',
        kind = _AnswerKind.thinking,
        csv = null,
        tokensPerSecond = null,
        completionTokens = null,
        reasoningTokens = null,
        isDone = false;
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
          final width =
              screen.width < 760 ? screen.width * 0.97 : screen.width * 0.9;
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

  /// Voice input for the question field itself (2026-09 user request:
  /// unlike [SearchableSelectField.enableVoiceInput]/[VoiceTransactionSheet]
  /// (both deliberately Android-only - see their own doc comments), this one
  /// is meant to work on every platform this app ships. `speech_to_text`
  /// 7.x actually ships federated web (`speech_to_text_web`) and Windows
  /// (`speech_to_text_windows`) implementations alongside Android - the
  /// earlier Android-only gates predate those, or were just never
  /// revisited - so no platform check here: [stt.SpeechToText.initialize]
  /// itself is the one source of truth for whether a given browser/OS can
  /// actually do it (declines cleanly to `false` when it can't, e.g. a
  /// browser without the Web Speech API), surfaced via [_speechError]
  /// rather than assumed in advance.
  stt.SpeechToText? _speech;
  String? _speechError;

  /// True from the moment the mic button is tapped until the user
  /// explicitly taps it again to stop - the one flag that actually drives
  /// the UI and dispose() (see [_toggleListening]'s own doc comment): a raw
  /// recognition segment can end and restart several times while this
  /// stays true throughout, so neither Android's `pauseFor`/`listenFor`
  /// window nor any other natural end are allowed to actually stop
  /// dictation on their own while it's still set.
  bool _userWantsListening = false;

  /// Confirmed text from every recognition segment *before* the current
  /// one (2026-09 user request: seamless continuous dictation across
  /// Chrome's own ~5s "no speech" cutoff - see [_toggleListening]). Each
  /// restarted segment's [stt.SpeechRecognitionResult.recognizedWords]
  /// starts over from nothing, so this is what makes the field keep
  /// growing instead of losing everything said before the restart.
  String _confirmedText = '';

  /// Slider at the top of the dialog (2026-09-10 user request: "un curseur
  /// de max_token... pour le régler de manière dynamique si nécessaire") -
  /// see [LlmEngine.maxTokens]. A plain token count, not a multiplier on
  /// some invisible base value - an earlier version showed "x2.5" etc.,
  /// which a follow-up user report called out as meaningless without
  /// knowing what it multiplied ("c'est y fois de quoi?"). Loaded once
  /// here, saved on every drag via [setLlmMaxTokens] - the exact same
  /// stored value Settings' own field (local_llm_settings_card.dart) reads/
  /// writes, so there's only ever one number to keep straight, just two
  /// places to adjust it from (the persistent default, and a quick
  /// per-session nudge here). Each backend re-reads it fresh per question,
  /// so a change here takes effect on the very next one, no restart needed.
  int _maxTokens = 2048;

  @override
  void initState() {
    super.initState();
    if (isLocalLlmSupported) {
      currentLlmModelLabel().then((label) {
        if (!mounted) return;
        setState(() => _modelLabel = label);
      });
      llmMaxTokens().then((value) {
        if (!mounted) return;
        setState(() => _maxTokens = value);
      });
    }
  }

  @override
  void dispose() {
    // Belt-and-braces, same reasoning as VoiceTransactionSheet.dispose: don't
    // leave the recognizer running past the widget that owns its callbacks
    // if the dialog is closed mid-listen.
    if (_userWantsListening) {
      _userWantsListening = false;
      _speech?.cancel();
    }
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

  /// Set once [stt.SpeechToText.initialize] has actually succeeded - so a
  /// restart in [_startListeningSegment] (see [_toggleListening]'s own doc
  /// comment) only calls `listen()` again rather than re-initializing (and
  /// re-registering the same callbacks) every few seconds.
  bool _speechInitialized = false;

  /// Dictates directly into [_controller], same "type-to-filter"-style
  /// pattern as [SearchableSelectField]'s mic button but with
  /// [stt.ListenMode.dictation] (a question is a sentence, not a couple of
  /// words). Never auto-submits: dictation can mishear a word, so the user
  /// always reviews/edits the transcribed text before tapping send, same "a
  /// wrong guess costs a tap to fix" principle as every other voice entry
  /// point in this app.
  ///
  /// [listenOptions.pauseFor]/[listenOptions.listenFor] passed to
  /// [_startListeningSegment] are only honoured on Android - confirmed
  /// 2026-09-09 by reading `speech_to_text`'s own web *and* Windows source:
  /// web's `listen()` implementation reads `partialResults` only and
  /// silently ignores `pauseFor`/`listenFor`/`cancelOnError` entirely, and
  /// Windows' method channel `listen()` doesn't even include them in the
  /// params map it sends to the native side. On both, the underlying
  /// platform's own speech engine (Chrome's Web Speech API, Windows' UWP
  /// `SpeechRecognizer`) decides on its own when to end a session on
  /// silence - not configurable through this package, and not the same
  /// cutoff on both (commonly a few seconds either way).
  ///
  /// Rather than accept that as a hard 5-ish-second cap on dictating a
  /// whole question (2026-09-09 user report), [_userWantsListening] tracks
  /// intent separately from any one segment: [_onSegmentEnded] restarts
  /// automatically whenever a segment ends on its own (silence) while the
  /// user hasn't explicitly tapped the mic to stop, carrying forward
  /// whatever was already transcribed via [_confirmedText] - each new
  /// segment's own [stt.SpeechRecognitionResult.recognizedWords] starts
  /// from nothing, so without this every restart would silently erase what
  /// came before it. From the user's perspective this reads as one
  /// continuous dictation on every platform, Android's genuinely
  /// long-running session included (a restart there is simply rarer).
  Future<void> _toggleListening() async {
    if (_userWantsListening) {
      _userWantsListening = false;
      await _speech?.stop();
      return;
    }
    _confirmedText = '';
    _userWantsListening = true;
    await _startListeningSegment();
  }

  /// Starts (or restarts) one recognition segment - see [_toggleListening].
  void _onSegmentEnded(String status) {
    if (!mounted) return;
    // Only a truly empty attempt (nothing transcribed across *any* segment
    // so far) counts as a real "no speech detected" failure worth
    // interrupting the loop for - a pause between two sentences mid
    // question must never look like an error just because *this* segment
    // in particular came back empty.
    final hasAnyText = _controller.text.trim().isNotEmpty;
    if (status == 'doneNoResult' && !hasAnyText) {
      setState(() {
        _speechError = "Aucune parole détectée - réessayez en parlant "
            "juste après avoir appuyé sur le micro.";
        _userWantsListening = false;
      });
    }
    if (_userWantsListening) {
      _confirmedText = _controller.text;
      _startListeningSegment();
    }
  }

  Future<void> _startListeningSegment() async {
    final speech = _speech ??= stt.SpeechToText();
    if (!_speechInitialized) {
      bool available;
      try {
        available = await speech.initialize(
          onError: (error) {
            if (!mounted) return;
            // Android's own SpeechRecognizer reports "no speech since I
            // started listening" as an *error* ('error_speech_timeout',
            // SpeechRecognizer.ERROR_SPEECH_TIMEOUT) rather than through
            // onStatus the way the web/Windows backends' equivalent
            // ('doneNoResult') does - confirmed 2026-09-09 live on a real
            // phone: a correctly-recognized sentence still surfaced this as
            // a scary "Erreur de reconnaissance vocale" and killed the
            // whole auto-restart loop, even though nothing had actually
            // gone wrong - it's just the natural end of a segment after a
            // pause, exactly like the other backends' 'doneNoResult'.
            // Routed through the same [_onSegmentEnded] path so it only
            // becomes a real user-visible error when nothing at all has
            // been transcribed yet - otherwise it silently restarts.
            if (error.errorMsg == 'error_speech_timeout') {
              _onSegmentEnded('doneNoResult');
              return;
            }
            setState(() {
              _userWantsListening = false;
              _speechError =
                  'Erreur de reconnaissance vocale (${error.errorMsg}).';
            });
          },
          onStatus: (status) {
            if (status == 'notListening' ||
                status == 'done' ||
                status == 'doneNoResult') {
              _onSegmentEnded(status);
            }
          },
        );
      } catch (_) {
        // Unlike the native Android backend, the web (Web Speech API) and
        // Windows backends can throw here instead of cleanly resolving to
        // `false` - a browser with no Web Speech API support at all (e.g.
        // not Chrome/Edge) or a denied microphone permission - found live
        // (2026-09) testing this exact button: an uncaught exception with
        // no visible feedback otherwise. Folded into the same
        // "indisponible" message as a clean `false`, since from the user's
        // perspective it's the same outcome (no dictation available right
        // now).
        available = false;
      }
      if (!mounted) return;
      if (!available) {
        setState(() {
          _userWantsListening = false;
          _speechError =
              "Reconnaissance vocale indisponible sur cet appareil/navigateur.";
        });
        return;
      }
      _speechInitialized = true;
    }
    if (!mounted || !_userWantsListening) return;
    setState(() => _speechError = null);
    unawaited(speech
        .listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _controller.text = _confirmedText.isEmpty
              ? result.recognizedWords
              : '$_confirmedText ${result.recognizedWords}';
          _controller.selection =
              TextSelection.collapsed(offset: _controller.text.length);
        });
      },
      listenOptions: stt.SpeechListenOptions(
        // BCP-47 with a hyphen, not the underscore form used by the
        // Android-only voice inputs elsewhere in the app (SearchableSelectField/
        // VoiceTransactionSheet) - found 2026-09-09 reading the Android
        // plugin's own Kotlin source: it normalizes 'fr_FR' to 'fr-FR'
        // itself before use (`localeId.replace('_', '-')`), but the web
        // backend passes it straight through to the browser's
        // `SpeechRecognition.lang`, which the Web Speech API spec (and
        // Windows' own locale API) require in hyphenated form - an
        // underscore isn't a valid BCP-47 tag there.
        localeId: 'fr-FR',
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 30),
      ),
    )
        .catchError((Object _) {
      // Same rationale as the initialize() try/catch above - listen() can
      // also throw on some backends rather than reporting failure through
      // onError/onStatus.
      if (!mounted) return;
      setState(() {
        _userWantsListening = false;
        _speechError =
            "Reconnaissance vocale indisponible sur cet appareil/navigateur.";
      });
    }));
  }

  /// How close to the bottom (in logical pixels) still counts as "was
  /// following along" for [_scrollToBottom]'s own auto-scroll gating below.
  static const _autoScrollThreshold = 80.0;

  /// Auto-scrolls to the newest message - but only if the user was already
  /// at (or very near) the bottom right before this call, i.e. actually
  /// following along. 2026-09-10 user report: while a "thinking" entry is
  /// streaming and growing, this used to fire on *every single chunk*,
  /// fighting any attempt to scroll back up to collapse it - "le
  /// défilement m'en empêche". Capturing the scroll position now, before
  /// the post-frame callback (which only runs once the new content has
  /// already extended the scrollable range), is what lets this tell "the
  /// user had deliberately scrolled away" apart from "nothing's scrolled
  /// yet, of course pixels < the old maxScrollExtent" - checking *after*
  /// the frame would always see a bigger maxScrollExtent than whatever the
  /// user was actually looking at.
  void _scrollToBottom() {
    double? pixelsBefore;
    double? maxScrollExtentBefore;
    if (_scrollController.hasClients) {
      pixelsBefore = _scrollController.position.pixels;
      maxScrollExtentBefore = _scrollController.position.maxScrollExtent;
    }
    // A frame needs to actually pass (the new message just got added to
    // the list) before there's anything new to scroll to - jumping inside
    // the same setState call would still see the old scroll extent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      if (pixelsBefore != null &&
          maxScrollExtentBefore != null &&
          maxScrollExtentBefore - pixelsBefore > _autoScrollThreshold) {
        return; // the user had scrolled away from the bottom - leave them be
      }
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

  /// Prints a whole answer (2026-09 user request: "envoyer la réponse vers
  /// une imprimante", both a phone's and a PC's own network printer) - a
  /// PDF handed to [Printing.layoutPdf], which opens the platform's own
  /// print dialog (Android/Windows/web all supported by the `printing`
  /// package) rather than talking to any printer directly: that dialog
  /// already lists whatever printers - network ones included - are already
  /// set up on the device, so this app never needs to know a printer's
  /// address itself. Real Markdown rendering (headings, bold, lists,
  /// tables...) and a Unicode-capable font - see answer_pdf.dart's own doc
  /// comment for the 2026-09-10 user report ("c'est dégueulasse") this
  /// replaced a much cruder plain-text version for.
  Future<void> _printAnswer(BuildContext context, String text) async {
    try {
      final doc = await buildAnswerPdfDocument(
        title: 'Money Manager',
        subtitle: DateFormat('d MMMM yyyy à HH:mm', 'fr_FR').format(DateTime.now()),
        markdownText: text,
      );
      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: 'reponse_ia.pdf',
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Échec de l'impression : $e")),
      );
    }
  }

  /// "Interrompre" (2026-08-31 user request) - invalidates the in-flight
  /// [_ask] call (see [_requestGeneration]/its `reply` closure) so its
  /// answer, whenever it eventually arrives, is silently dropped instead of
  /// popping into the transcript after the user has moved on, and resets
  /// the UI to ready-for-input immediately.
  ///
  /// Mostly a *client-side* cancel: the in-flight HTTP request itself
  /// isn't aborted (the backend already has the request; the server keeps
  /// generating regardless), `reply`/the streaming `onChunk` callbacks
  /// below just stop touching state once `myGeneration` no longer matches
  /// - already-spent server-side compute/cost can't be un-happened either
  /// way. The one case where this genuinely stops real work is the desktop
  /// build's own spawned local `llama-server.exe`: [shutdownLocalLlmEngine]
  /// kills that process outright, which does immediately free the CPU/GPU
  /// it was using - worth doing regardless of backend, since it's a no-op
  /// everywhere else and the next question simply pays a fresh engine's
  /// startup cost instead.
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

    // The live "thinking" entry currently being filled in, if any - see
    // _AnswerKind.thinking's own doc comment. A new phase (a different
    // [phaseLabel] than the one currently open) finalizes the previous
    // entry and starts a fresh one; the same phase repeating (e.g. several
    // back-to-back SQL-fix attempts) keeps appending to the same one
    // rather than fragmenting into a separate bubble per retry.
    _ChatEntry? currentThinking;
    void onProgress(String phaseLabel, String text, bool isReasoning) {
      if (myGeneration != _requestGeneration) return;
      var entry = currentThinking;
      if (entry == null || entry.phaseLabel != phaseLabel) {
        entry?.isDone = true;
        entry = _ChatEntry.thinking(phaseLabel);
        currentThinking = entry;
        setState(() => _messages.add(entry!));
      }
      setState(() => entry!.text += text);
      _scrollToBottom();
    }

    void reply(String text, _AnswerKind kind,
        {String? csv,
        double? tokensPerSecond,
        int? completionTokens,
        int? reasoningTokens}) {
      if (myGeneration != _requestGeneration) return;
      currentThinking?.isDone = true;
      setState(() {
        _loading = false;
        _messages.add(_ChatEntry.assistant(text, kind,
            csv: csv,
            tokensPerSecond: tokensPerSecond,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens));
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
              repo: repo, history: history, onProgress: onProgress)
          : await askLocalLlmWithFullDataAccess(trimmed,
              dbPath: repo.db.label, history: history, onProgress: onProgress);
      switch (sqlOutcome) {
        case SqlAccessSuccess(:final answer):
          reply(answer.text, _AnswerKind.sqlGrounded,
              csv: answer.csv,
              tokensPerSecond: answer.tokensPerSecond,
              completionTokens: answer.completionTokens,
              reasoningTokens: answer.reasoningTokens);
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
      final freeform = await askLocalLlmFreeform(trimmed,
          history: history,
          onChunk: (text, isReasoning) =>
              onProgress('Réponse', text, isReasoning));
      switch (freeform) {
        case LlmFreeformSuccess(
            :final text,
            :final tokensPerSecond,
            :final completionTokens,
            :final reasoningTokens
          ):
          reply(text, _AnswerKind.freeform,
              tokensPerSecond: tokensPerSecond,
              completionTokens: completionTokens,
              reasoningTokens: reasoningTokens);
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

  /// Caption shown under an answer bubble (2026-08-31: tokens/s alone;
  /// 2026-09-10 user request: "ajouter le nombre de token généré en
  /// différentiant thinking et réponse") - built from whichever of
  /// [_ChatEntry.completionTokens]/[reasoningTokens]/[tokensPerSecond] the
  /// backend actually reported, never inventing a number for one that's
  /// null (see [LlmResponse]'s own doc comment). Null (nothing shown) only
  /// when none of the three are available at all.
  String? _tokenCaption(_ChatEntry entry) {
    final parts = <String>[];
    final total = entry.completionTokens;
    final reasoning = entry.reasoningTokens;
    if (total != null) {
      if (reasoning != null) {
        final answerTokens = total - reasoning;
        parts.add('$total tokens (dont $reasoning en réflexion, '
            '$answerTokens en réponse)');
      } else {
        parts.add('$total tokens');
      }
    }
    if (entry.tokensPerSecond != null) {
      parts.add('${entry.tokensPerSecond!.toStringAsFixed(1)} tokens/s');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _buildBubble(BuildContext context, _ChatEntry entry) {
    final theme = Theme.of(context);
    if (entry.kind == _AnswerKind.thinking) {
      return _ThinkingBubble(entry: entry);
    }
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
                  TextButton.icon(
                    onPressed: () => _printAnswer(context, entry.text),
                    icon: const Icon(Icons.print_outlined, size: 16),
                    label: const Text('Imprimer'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
              if (_tokenCaption(entry) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _tokenCaption(entry)!,
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
    // Locks along with the rest of the app (2026-09-10 user report: the app
    // locked itself in the background while this dialog was open, but the
    // dialog stayed fully usable, showing real financial data straight
    // through the lock screen) - for the exact same structural reason
    // SelectionArea needed its own copy just below: `showDialog` pushes
    // this dialog as a *separate* route on the app's outermost Navigator
    // (app.dart's `_PinGate`), a sibling of - not a descendant of -
    // `_GateContent`'s conditional PIN-screen/real-app switch, so locking
    // never reaches a route already pushed on top of it. Checked here
    // instead, on every rebuild PinLockProvider's own status change
    // triggers. Deliberately returns a *replacement* build (never pops
    // this dialog) - the whole point is that every field/message already
    // typed/received is still here, untouched, the moment the real PIN
    // screen unlocks and this rebuilds again with `pinLock.status` back to
    // unlocked/none.
    final pinLock = context.watch<PinLockProvider>();
    if (pinLock.status != PinGateStatus.unlocked &&
        pinLock.status != PinGateStatus.none) {
      return const _LockedDialogBody();
    }
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
    // Its own ScaffoldMessenger (2026-09-10 user report: "fait en sorte
    // que la fenêtre ne se superpose pas aux messages en bas" - a SnackBar
    // shown via ScaffoldMessenger.of(context) was bubbling all the way up
    // to the app's own root Scaffold (home_shell.dart), which sits behind
    // this dialog and spans the *whole window* - so the SnackBar rendered
    // at the bottom of the entire screen instead of the bottom of this
    // dialog's own (smaller, inset) bounds, overlapping the question field
    // in a way that looked broken rather than like a normal SnackBar. A
    // fresh ScaffoldMessenger here means every `ScaffoldMessenger.of(context)`
    // call from *this* dialog's own descendants (copy/print/export
    // confirmations) finds this local one first and gets positioned
    // relative to the dialog's own [Scaffold] instead.
    return SelectionArea(
      child: ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: Column(
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
              if (isLocalLlmSupported)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Row(
                    children: [
                      Tooltip(
                        message: 'Nombre maximum de tokens que le modèle peut '
                            'utiliser pour chaque étape - à augmenter si les '
                            'réponses s\'arrêtent net sans avoir rien dit (un '
                            'modèle "thinking" qui épuise ce budget en '
                            'réfléchissant avant de répondre). Même réglage '
                            'que dans Paramètres.',
                        child: Icon(Icons.psychology_outlined,
                            size: 18,
                            color: Theme.of(context).colorScheme.outline),
                      ),
                      Expanded(
                        child: Slider(
                          value: _maxTokens.toDouble(),
                          min: 512,
                          max: 16384,
                          divisions: 31,
                          label: '$_maxTokens tokens',
                          onChanged: (value) =>
                              setState(() => _maxTokens = value.round()),
                          onChangeEnd: (value) =>
                              setLlmMaxTokens(value.round()),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text('$_maxTokens',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
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
              if (_speechError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    _speechError!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error),
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
                      key: const Key('nlQueryMicButton'),
                      tooltip: _userWantsListening
                          ? 'Arrêter la dictée'
                          : 'Dicter la question',
                      onPressed: _loading ? null : _toggleListening,
                      // Driven by _userWantsListening, not _listening - the
                      // brief gap between an auto-restarted segment ending
                      // and the next one starting (see _toggleListening's own
                      // doc comment) must never blink the mic off, since
                      // dictation is still conceptually ongoing.
                      icon: Icon(
                          _userWantsListening ? Icons.mic : Icons.mic_none),
                      style: _userWantsListening
                          ? IconButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.error,
                              foregroundColor:
                                  Theme.of(context).colorScheme.onError,
                            )
                          : null,
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
      ),
    );
  }
}

/// One live "thinking" step (2026-09-10 user request) - collapsible,
/// expanded by default (explicit user choice: "pliable/dépliable, déplié
/// par défaut"), title is [_ChatEntry.phaseLabel] plus a small spinner
/// while [_ChatEntry.isDone] is still false, body is the growing
/// [_ChatEntry.text] itself. [ObjectKey] on the outer [ExpansionTile] -
/// not the list index - so Flutter keeps tracking *this* entry's own
/// expanded/collapsed state (if the user toggled it) across every rebuild
/// a new chunk triggers, rather than resetting it each time.
/// Replaces [NlQueryDialog]'s whole visible content while the app is
/// locked (2026-09-10 user request) - see [_NlQueryDialogState.build]'s own
/// doc comment for why this dialog needs to check that itself rather than
/// automatically inheriting the app-wide PIN gate. Same dark [Material]
/// background as the real dialog content (so this doesn't flash a
/// different color while swapped in).
///
/// Embeds the real [PinUnlockForm] directly (2026-09-10, same day - first
/// version showed a static "Application verrouillée" message with no way to
/// act on it from here, so the only way to actually unlock was to tap
/// outside the dialog's own modal barrier to dismiss it and reach the app's
/// separate [PinUnlockScreen] underneath - which, being a *dismiss*, popped
/// this dialog's route and destroyed its whole conversation right as the
/// user unlocked, the exact state loss this whole fix exists to prevent;
/// confirmed live by the user: "une fois dévérouiller la fenêtre de
/// question a été fermée du fait que j'ai du cliquer hors de la fenêtre").
/// [PinUnlockForm.verify] acts directly on the one shared [PinLockProvider]
/// instance, so entering the code here unlocks the whole app too - no
/// barrier tap, no route change, nothing to dismiss.
class _LockedDialogBody extends StatelessWidget {
  const _LockedDialogBody();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: PinUnlockForm(),
          ),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  final _ChatEntry entry;

  const _ThinkingBubble({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: ObjectKey(entry),
              initiallyExpanded: true,
              dense: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              leading: entry.isDone
                  ? Icon(Icons.psychology_outlined,
                      size: 18, color: theme.colorScheme.outline)
                  : SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.outline,
                      ),
                    ),
              title: Text(
                entry.phaseLabel ?? '',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.outline,
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    entry.text.isEmpty ? '...' : entry.text,
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
