import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Only ever imported from local_llm_manager_io.dart, itself only reached
/// after that file's own `Platform.isWindows` gate - see CLAUDE.md's
/// conditional-import-shell rule. This file has no `dart:io`/`dart:ffi` of
/// its own (it's a pure HTTP client, doesn't even know a process is
/// involved - local_llm_manager_io.dart owns spawning/killing
/// `llama-server.exe` and just hands this class a port once it's up), so
/// nothing here actually *requires* being Windows-only - it's kept behind
/// the same gate anyway purely because nothing reaches it any other way.
///
/// Talks to a locally-spawned llama.cpp server over plain HTTP instead of
/// an FFI binding to a native library - see ROADMAP.md for why the earlier
/// `llama_cpp_dart` approach was abandoned (2026-08-03): neither Dart FFI
/// package for llama.cpp (`llama_cpp_dart`, `llamadart`) ships a working
/// prebuilt Windows binary, so getting a compatible native library in place
/// was never actually verifiable. llama.cpp's own official GitHub releases
/// *do* ship a ready-to-run `llama-server.exe` for Windows - no Dart-side
/// native compatibility concerns at all, since the app never links against
/// it directly, only talks to it over localhost HTTP.
///
/// The request/response shapes here match llama.cpp server's documented
/// HTTP API as of this writing, verified against a fake local HTTP server
/// standing in for the real thing (see llama_server_client_test.dart) -
/// but whether a *real* llama-server.exe actually behaves this way (does
/// the grammar actually constrain output, is the JSON usable) can only be
/// confirmed on a real Windows machine running it. Every failure path is
/// designed to throw rather than hang or silently misbehave, so the caller
/// (local_llm_manager_io.dart) always has a safe fallback to the
/// rule-based parser.

/// Standard llama.cpp JSON grammar (GBNF) - constrains sampling so the
/// model can only ever produce syntactically valid JSON, never prose or a
/// broken partial object. Deliberately not narrowed to this app's exact
/// intent schema (hand-writing that reliably in GBNF wasn't practical to
/// verify without a real server to test against) - see
/// intent_json_codec.dart for the schema/semantic validation that happens
/// after decoding.
const jsonGrammar = r'''
root   ::= object
value  ::= object | array | string | number | ("true" | "false" | "null") ws

object ::=
  "{" ws (
            string ":" ws value
    ("," ws string ":" ws value)*
  )? "}" ws

array  ::=
  "[" ws (
            value
    ("," ws value)*
  )? "]" ws

string ::=
  "\"" (
    [^"\\\x7F\x00-\x1F] |
    "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4})
  )* "\"" ws

number ::= ("-"? ([0-9] | [1-9] [0-9]*)) ("." [0-9]+)? ([eE] [-+]? [0-9]+)? ws

ws ::= | " " | "\n" [ \t]{0,20}
''';

const _systemPrompt = '''
Tu extrais une intention structurée d'une question posée en français sur une base de finances personnelles. Réponds UNIQUEMENT avec un objet JSON, sans aucun texte autour, au format suivant :
{"kind": "...", "period": "...", "category": "...", "account": "...", "payee": "...", "topN": ..., "metric": "...", "transactionType": "...", "groupBy": "...", "recurringOnly": ...}

- "kind" doit être exactement l'une de ces valeurs : adHoc, balance, outlook, incomeVsExpense.
  - "adHoc" pour TOUTE question qui revient à filtrer puis agréger des opérations : un total de dépenses ou de revenus, un classement ("mes plus grosses dépenses"), une dépense chez un tiers précis, une répartition par catégorie/mois/compte/tiers, des opérations récurrentes, un nombre d'opérations, une moyenne, etc. C'est le choix par défaut : en cas de doute, choisis "adHoc".
  - "balance" seulement pour une question sur le solde d'un compte à un instant donné.
  - "outlook" seulement pour une question du type "vais-je finir le mois en négatif / dans le rouge / à découvert".
  - "incomeVsExpense" seulement pour une question qui compare explicitement revenus ET dépenses ensemble.
- "period" est la portion de la question qui décrit une période (ex: "juillet 2026", "le mois dernier", "cette année", "depuis janvier"), ou null si aucune n'est mentionnée.
- "category", "account", "payee" sont les noms mentionnés dans la question (ou null s'ils ne sont pas mentionnés) - recopie seulement ce que dit la question, n'en invente jamais.
- "topN" est un nombre si la question en demande un explicitement (ex: "top 10", "mes 3 plus grosses..."), sinon null - laisse null si la question ne demande pas de classement limité, même pour "adHoc" avec un "groupBy".
- Uniquement pour "kind": "adHoc", précise aussi (laisse ces 4 champs à null pour tout autre "kind") :
  - "metric" : "sum" (un total), "count" (un nombre d'opérations), ou "average" (une moyenne).
  - "transactionType" : "withdrawal" (dépenses), "deposit" (revenus), "transfer" (virements), ou "any" (tout, y compris les virements - se combine surtout avec "count").
  - "groupBy" : "none" (un seul total), "category", "month", "payee", ou "account" - selon si la question demande une répartition et par quoi.
  - "recurringOnly" : true seulement si la question mentionne explicitement des opérations "récurrentes", sinon false.
N'invente jamais de montant, de date précise, ou de nom de catégorie/compte/tiers absent de la question : ce sont d'autres calculs qui s'en chargent, pas toi.
''';

/// Qwen2.5's own chat format (ChatML) - both catalog models (see
/// model_catalog.dart) are Qwen2.5 Instruct, so this is hardcoded rather
/// than relying on llama-server's own chat-template auto-detection:
/// predictable, and matches exactly what the previous FFI-based engine's
/// `ChatMLFormat()` produced. `/completion` is a raw-text endpoint with no
/// notion of chat turns on its own, so this formatting has to happen here.
String chatMlPrompt(String question) =>
    '<|im_start|>system\n$_systemPrompt<|im_end|>\n'
    '<|im_start|>user\n$question<|im_end|>\n'
    '<|im_start|>assistant\n';

const _freeformSystemPrompt = '''
Tu es un assistant utile qui répond en français, de façon concise. Tu fais partie d'une application de gestion de finances personnelles, mais tu n'as ici accès à aucune donnée financière de l'utilisateur (ni comptes, ni transactions, ni soldes) - si la question porte sur ses dépenses, revenus ou soldes, dis-le et invite-le à la reformuler comme une question sur ses finances plutôt que d'inventer un chiffre.
''';

/// Same ChatML framing as [chatMlPrompt], but the plain conversational
/// system prompt used by [LlamaServerClient.askFreeform] instead of the
/// intent-extraction one - kept as a top-level function (rather than
/// inlined) purely so it's directly unit-testable the same way
/// [chatMlPrompt] already is.
String freeformChatMlPrompt(String question) =>
    '<|im_start|>system\n$_freeformSystemPrompt<|im_end|>\n'
    '<|im_start|>user\n$question<|im_end|>\n'
    '<|im_start|>assistant\n';

/// Same ChatML framing as [chatMlPrompt]/[freeformChatMlPrompt], but with a
/// caller-supplied system prompt instead of either hardcoded one - backs
/// [LlamaServerClient.askWithSystemPrompt]/[askFreeformWithSystemPrompt],
/// used by the full-database-access SQL query mode (sql_query_engine.dart),
/// whose system prompt is itself a user-editable Settings value.
String chatMlPromptWithSystem(String systemPrompt, String question) =>
    '<|im_start|>system\n$systemPrompt<|im_end|>\n'
    '<|im_start|>user\n$question<|im_end|>\n'
    '<|im_start|>assistant\n';

/// Talks HTTP to whatever's already listening on [host]:[port] - entirely
/// unaware of whether that's a real `llama-server.exe` process or (in
/// tests) a fake stand-in; spawning/killing the real process, and deciding
/// what host/port it listens on, is local_llm_manager_io.dart's job, not
/// this class's.
class LlamaServerClient {
  final int port;
  final String host;
  final http.Client _client;

  LlamaServerClient(this.port, {this.host = '127.0.0.1'}) : _client = http.Client();

  /// One-shot, non-polling health check - true only on a 200 from
  /// `/health`, false on any other status, and false on any connection
  /// failure (server not running, wrong port, network unreachable). Backs
  /// Settings' "Tester la connexion" button; the question flow itself
  /// deliberately does *not* use this - a question is cheap to attempt and
  /// its own per-request timeout bounds the wait (see
  /// local_llm_manager_web.dart).
  Future<bool> healthCheck() async {
    try {
      final response = await _client
          .get(Uri.parse('http://$host:$port/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Polls `/health` until it answers 200, or throws once [timeout]
  /// elapses - loading a multi-gigabyte model, especially with layers
  /// offloaded to the GPU for the first time on a cold disk cache, is
  /// genuinely slow to start. [hasExited] lets the caller report "the
  /// process already died" so this can fail fast instead of waiting out
  /// the full timeout polling a port nothing will ever answer on again.
  Future<void> waitUntilHealthy({
    required Duration timeout,
    bool Function() hasExited = _neverExited,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (hasExited()) {
        throw StateError("Le serveur a quitté avant de devenir disponible.");
      }
      try {
        final response = await _client
            .get(Uri.parse('http://$host:$port/health'))
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return;
      } catch (_) {
        // Not up yet - keep polling until the deadline.
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    throw StateError("Le serveur n'a pas répondu à temps sur le port $port.");
  }

  /// Runs a single, stateless question through the model (this app never
  /// keeps a multi-turn chat history - each question is answered fresh)
  /// and returns its raw text response, for intent_json_codec.dart to
  /// decode. Never catches a generation failure - the caller
  /// (local_llm_manager_io.dart) is responsible for that and falling back
  /// to the rule-based parser.
  Future<String> ask(String question) async {
    final response = await _client.post(
      Uri.parse('http://$host:$port/completion'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'prompt': chatMlPrompt(question),
        'grammar': jsonGrammar,
        'temperature': 0.1,
        'n_predict': 256,
        'stop': ['<|im_end|>'],
        'stream': false,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('llama-server a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['content'] as String? ?? '';
  }

  /// Same shape as [ask], but no JSON grammar and a plain conversational
  /// system prompt instead of the intent-extraction one - used only once
  /// nl_query_dialog.dart has already established the question matches no
  /// recognized financial-question shape (see [chatMlPrompt]/[jsonGrammar]),
  /// so there is nothing left to lose by letting the model just answer in
  /// prose instead of returning "je n'ai pas compris". A higher
  /// [n_predict]/temperature than [ask] on purpose: that one wants a short,
  /// deterministic JSON object, this one wants a normal, natural-sounding
  /// reply.
  Future<String> askFreeform(String question) async {
    final response = await _client.post(
      Uri.parse('http://$host:$port/completion'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'prompt': freeformChatMlPrompt(question),
        'temperature': 0.7,
        'n_predict': 512,
        'stop': ['<|im_end|>'],
        'stream': false,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('llama-server a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['content'] as String? ?? '';
  }

  /// Same shape as [ask] (JSON-grammar-constrained, low temperature - a
  /// structured, deterministic response is the goal), but with a
  /// caller-supplied [systemPrompt] instead of the fixed intent-extraction
  /// one - backs the full-database-access SQL query mode
  /// (sql_query_engine.dart's `answerViaFullSqlAccess`), whose system
  /// prompt is a user-editable Settings value, not a constant this class
  /// can hardcode. Higher [n_predict] than [ask]: a SQL query with several
  /// JOINs/CASE expressions - or a whole multi-step plan object with
  /// several such queries - genuinely needs more tokens than a short
  /// intent JSON object does.
  Future<String> askWithSystemPrompt(String systemPrompt, String question) async {
    final response = await _client.post(
      Uri.parse('http://$host:$port/completion'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'prompt': chatMlPromptWithSystem(systemPrompt, question),
        'grammar': jsonGrammar,
        'temperature': 0.1,
        'n_predict': 1024,
        'stop': ['<|im_end|>'],
        'stream': false,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('llama-server a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['content'] as String? ?? '';
  }

  /// Same shape as [askFreeform] (no grammar, prose out), but with a
  /// caller-supplied [systemPrompt] - the second step of the
  /// full-database-access SQL query mode, grounding the final French
  /// answer in the query's real result rows (see
  /// sql_query_engine.dart's `answerViaFullSqlAccess`). Lower temperature
  /// than [askFreeform] on purpose: this is meant to faithfully paraphrase
  /// real data, not converse freely. Higher [n_predict] than the old
  /// fixed "one or two sentences" answer: in report mode (see
  /// sql_query_engine.dart's `buildAnswerFormattingPrompt`) the answer is
  /// a structured, multi-section breakdown that a few hundred tokens
  /// would cut off mid-sentence.
  Future<String> askFreeformWithSystemPrompt(String systemPrompt, String question) async {
    final response = await _client.post(
      Uri.parse('http://$host:$port/completion'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'prompt': chatMlPromptWithSystem(systemPrompt, question),
        'temperature': 0.2,
        'n_predict': 2048,
        'stop': ['<|im_end|>'],
        'stream': false,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('llama-server a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded['content'] as String? ?? '';
  }

  void close() => _client.close();
}

bool _neverExited() => false;
