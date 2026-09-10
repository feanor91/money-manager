import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_engine.dart';
import 'think_tag_splitter.dart';

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

/// The intent-extraction system prompt - public (not `_`-prefixed) so
/// cloud_llm_client.dart can reuse the exact same wording rather than
/// duplicating this carefully-tuned prose for a second backend.
const intentSystemPrompt = '''
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

/// Qwen2.5's own chat format (ChatML) - every catalog model (see
/// model_catalog.dart) is Qwen2.5 Instruct, so this is hardcoded rather
/// than relying on llama-server's own chat-template auto-detection:
/// predictable, and matches exactly what the previous FFI-based engine's
/// `ChatMLFormat()` produced. `/completion` is a raw-text endpoint with no
/// notion of chat turns on its own, so this formatting has to happen here.
String chatMlPrompt(String question) =>
    '<|im_start|>system\n$intentSystemPrompt<|im_end|>\n'
    '<|im_start|>user\n$question<|im_end|>\n'
    '<|im_start|>assistant\n';

/// See [intentSystemPrompt] - public for the same reason.
const freeformSystemPrompt = '''
Tu es un assistant utile qui répond en français, de façon concise. Tu fais partie d'une application de gestion de finances personnelles, mais tu n'as ici accès à aucune donnée financière de l'utilisateur (ni comptes, ni transactions, ni soldes) - si la question porte sur ses dépenses, revenus ou soldes, dis-le et invite-le à la reformuler comme une question sur ses finances plutôt que d'inventer un chiffre.
''';

/// Same ChatML framing as [chatMlPrompt], but the plain conversational
/// system prompt used by [LlamaServerClient.askFreeform] instead of the
/// intent-extraction one - kept as a top-level function (rather than
/// inlined) purely so it's directly unit-testable the same way
/// [chatMlPrompt] already is.
String freeformChatMlPrompt(String question) =>
    '<|im_start|>system\n$freeformSystemPrompt<|im_end|>\n'
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
class LlamaServerClient implements LlmEngine {
  final int port;
  final String host;

  /// Optional bearer token, sent as `Authorization: Bearer <apiKey>` on
  /// every request when non-null/non-empty - matches llama-server's own
  /// `--api-key` flag. Irrelevant (and harmless to leave unset) for a
  /// loopback-only server the desktop build spawns itself, but this is
  /// what secures a server reached remotely (see
  /// local_llm_settings_card.dart's web/Android variants) - without it,
  /// anyone who finds the address could use the PC's GPU and see its
  /// answers, since llama-server has no authentication of its own by
  /// default.
  final String? apiKey;

  final http.Client _client;

  @override
  int maxTokens = 2048;

  LlamaServerClient(this.port, {this.host = '127.0.0.1', this.apiKey})
      : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      };

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
          .get(Uri.parse('http://$host:$port/health'), headers: _headers)
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
            .get(Uri.parse('http://$host:$port/health'), headers: _headers)
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return;
      } catch (_) {
        // Not up yet - keep polling until the deadline.
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    throw StateError("Le serveur n'a pas répondu à temps sur le port $port.");
  }

  /// Parses a `/completion` response into an [LlmResponse] - `content` is
  /// the generated text; `tokens_predicted` (llama.cpp's own field name for
  /// the real generated-token count, present on every real llama-server
  /// response) combined with [elapsedMs] (measured client-side around the
  /// request - the response carries no server-side timing this class
  /// currently reads) gives a genuine tokens/second figure. Null rather
  /// than estimated whenever `tokens_predicted` is missing/zero or nothing
  /// elapsed - never invented, same rule [LlmResponse] itself documents.
  LlmResponse _parseResponse(http.Response response, int elapsedMs) {
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = decoded['content'] as String? ?? '';
    final tokens = decoded['tokens_predicted'] as int?;
    final tps = (tokens != null && tokens > 0 && elapsedMs > 0)
        ? tokens / (elapsedMs / 1000)
        : null;
    // completionTokens only - llama.cpp's own /completion API has no
    // concept of a separate reasoning-token count the way some OpenAI-
    // compatible cloud providers do (see LlmResponse.reasoningTokens).
    return LlmResponse(text, tokensPerSecond: tps, completionTokens: tokens);
  }

  /// Shared by all four `ask*` methods below - builds the right `/completion`
  /// request body and either awaits it whole ([onChunk] null) or streams it
  /// ([onChunk] given - see [LlmEngine.ask]'s own doc comment).
  Future<LlmResponse> _complete({
    required String prompt,
    required double temperature,
    String? grammar,
    LlmChunkCallback? onChunk,
  }) {
    return onChunk == null
        ? _completeOnce(prompt: prompt, temperature: temperature, grammar: grammar)
        : _completeStreamed(
            prompt: prompt, temperature: temperature, grammar: grammar, onChunk: onChunk);
  }

  Map<String, Object?> _requestBody({
    required String prompt,
    required double temperature,
    required String? grammar,
    required bool stream,
  }) =>
      {
        'prompt': prompt,
        if (grammar != null) 'grammar': grammar,
        'temperature': temperature,
        'n_predict': maxTokens,
        'stop': ['<|im_end|>'],
        'stream': stream,
      };

  Future<LlmResponse> _completeOnce({
    required String prompt,
    required double temperature,
    required String? grammar,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _client.post(
      Uri.parse('http://$host:$port/completion'),
      headers: _headers,
      body: jsonEncode(_requestBody(
        prompt: prompt,
        temperature: temperature,
        grammar: grammar,
        stream: false,
      )),
    );
    stopwatch.stop();
    if (response.statusCode != 200) {
      throw StateError('llama-server a répondu ${response.statusCode}.');
    }
    return _parseResponse(response, stopwatch.elapsedMilliseconds);
  }

  /// llama.cpp's own `/completion` SSE shape: repeated `data: {...}\n\n`
  /// lines, each carrying just the newly-generated `content` fragment (not
  /// cumulative, unlike some providers), the last one flagged `"stop":
  /// true` and (only there) including the real `tokens_predicted` count.
  /// No structured reasoning field the way OpenRouter can have - a local
  /// model's own chain-of-thought, if any, only ever shows up inline as
  /// `<think>` tags in the plain `content` stream itself, so every chunk
  /// goes through [ThinkTagSplitter] unconditionally.
  Future<LlmResponse> _completeStreamed({
    required String prompt,
    required double temperature,
    required String? grammar,
    required LlmChunkCallback onChunk,
  }) async {
    final stopwatch = Stopwatch()..start();
    final request = http.Request('POST', Uri.parse('http://$host:$port/completion'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(_requestBody(
        prompt: prompt,
        temperature: temperature,
        grammar: grammar,
        stream: true,
      ));
    final streamed = await _client.send(request);
    if (streamed.statusCode != 200) {
      throw StateError('llama-server a répondu ${streamed.statusCode}.');
    }
    final answerBuffer = StringBuffer();
    final splitter = ThinkTagSplitter();
    int? tokensPredicted;
    await for (final line
        in streamed.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      final Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue; // a malformed/partial SSE line - skip rather than crash
      }
      final contentDelta = chunk['content'] as String?;
      if (contentDelta != null && contentDelta.isNotEmpty) {
        for (final (text, isReasoning) in splitter.feed(contentDelta)) {
          if (!isReasoning) answerBuffer.write(text);
          onChunk(text, isReasoning);
        }
      }
      if (chunk['stop'] == true) {
        tokensPredicted = chunk['tokens_predicted'] as int?;
        break;
      }
    }
    for (final (text, isReasoning) in splitter.finish()) {
      if (!isReasoning) answerBuffer.write(text);
      onChunk(text, isReasoning);
    }
    stopwatch.stop();
    final elapsedMs = stopwatch.elapsedMilliseconds;
    final tokens = tokensPredicted;
    final tps = (tokens != null && tokens > 0 && elapsedMs > 0)
        ? tokens / (elapsedMs / 1000)
        : null;
    return LlmResponse(answerBuffer.toString(),
        tokensPerSecond: tps, completionTokens: tokens);
  }

  /// Runs a single, stateless question through the model (this app never
  /// keeps a multi-turn chat history - each question is answered fresh)
  /// and returns its raw text response, for intent_json_codec.dart to
  /// decode. Never catches a generation failure - the caller
  /// (local_llm_manager_io.dart) is responsible for that and falling back
  /// to the rule-based parser.
  @override
  Future<LlmResponse> ask(String question, {LlmChunkCallback? onChunk}) => _complete(
        prompt: chatMlPrompt(question),
        grammar: jsonGrammar,
        temperature: 0.1,
        onChunk: onChunk,
      );

  /// Same shape as [ask], but no JSON grammar and a plain conversational
  /// system prompt instead of the intent-extraction one - used only once
  /// nl_query_dialog.dart has already established the question matches no
  /// recognized financial-question shape (see [chatMlPrompt]/[jsonGrammar]),
  /// so there is nothing left to lose by letting the model just answer in
  /// prose instead of returning "je n'ai pas compris". A higher temperature
  /// than [ask] on purpose: that one wants a short, deterministic JSON
  /// object, this one wants a normal, natural-sounding reply.
  @override
  Future<LlmResponse> askFreeform(String question, {LlmChunkCallback? onChunk}) => _complete(
        prompt: freeformChatMlPrompt(question),
        temperature: 0.7,
        onChunk: onChunk,
      );

  /// Same shape as [ask] (JSON-grammar-constrained, low temperature - a
  /// structured, deterministic response is the goal), but with a
  /// caller-supplied [systemPrompt] instead of the fixed intent-extraction
  /// one - backs the full-database-access SQL query mode
  /// (sql_query_engine.dart's `answerViaFullSqlAccess`), whose system
  /// prompt is a user-editable Settings value, not a constant this class
  /// can hardcode.
  @override
  Future<LlmResponse> askWithSystemPrompt(String systemPrompt, String question,
          {LlmChunkCallback? onChunk}) =>
      _complete(
        prompt: chatMlPromptWithSystem(systemPrompt, question),
        grammar: jsonGrammar,
        temperature: 0.1,
        onChunk: onChunk,
      );

  /// Same shape as [askFreeform] (no grammar, prose out), but with a
  /// caller-supplied [systemPrompt] - the second step of the
  /// full-database-access SQL query mode, grounding the final French
  /// answer in the query's real result rows (see
  /// sql_query_engine.dart's `answerViaFullSqlAccess`). Lower temperature
  /// than [askFreeform] on purpose: this is meant to faithfully paraphrase
  /// real data, not converse freely.
  @override
  Future<LlmResponse> askFreeformWithSystemPrompt(String systemPrompt, String question,
          {LlmChunkCallback? onChunk}) =>
      _complete(
        prompt: chatMlPromptWithSystem(systemPrompt, question),
        temperature: 0.2,
        onChunk: onChunk,
      );

  @override
  void close() => _client.close();
}

bool _neverExited() => false;
