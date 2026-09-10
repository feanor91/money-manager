import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llama_server_client.dart' show intentSystemPrompt, freeformSystemPrompt;
import 'llm_engine.dart';
import 'think_tag_splitter.dart';

/// Pre-filled into Settings' "Nom du modèle" field the first time a user
/// opens the cloud AI section (before they've ever set their own value) -
/// not a hardcoded requirement, just a sane starting point on OpenRouter's
/// free tier. Chosen 2026-09-03 after a real side-by-side: the previously
/// pre-filled `nvidia/nemotron-3-super-120b-a12b:free` is a reasoning model
/// (chain-of-thought on by default), and this app's two-call flow
/// (intent-extraction JSON, then SQL-writing JSON - see
/// sql_query_engine.dart/intent_json_codec.dart) needs every response to be
/// strict, parseable JSON with nothing else around it. A reasoning model's
/// hidden narration can still eat the whole `max_tokens` budget before
/// reaching real output even with `'reasoning': {'exclude': true}` sent
/// (see [CloudLlmClient._chat]'s own comment on that flag, and
/// `_stripReasoning`'s doc comment on the leftover `<think>` case) - both
/// of which are defenses against exactly this, not guarantees. Confirmed by
/// a real user test the same day: with the nemotron model, an "opérations
/// vétérinaire sur 2 ans, montants + notes + périodicité" question silently
/// fell all the way back to the closed rule-based engine (no notes, no
/// periodicity - both AI calls quietly declined); switching to
/// `minimax/minimax-m3:free` - a model tuned for agentic/tool-use tasks
/// (structured JSON, function calling) rather than displayed reasoning -
/// answered correctly end-to-end on the first try, verified row-by-row
/// against the real database. Never assumed to still be free or even to
/// still exist on OpenRouter indefinitely - it's a starting point the user
/// can freely override in Settings, not a guarantee.
const defaultCloudLlmModel = 'minimax/minimax-m3:free';

/// Talks to any OpenAI-compatible `/v1/chat/completions` HTTP endpoint - a
/// real hosted provider (OpenAI, Mistral, Groq, OpenRouter, ...) or the
/// user's own `llama-server.exe` reached remotely (it speaks this same
/// OpenAI-compatible API alongside the native `/completion` one
/// [LlamaServerClient] uses - see local_llm_settings_card.dart's Android
/// variant). From this client's point of view a real cloud provider and
/// "my own PC, reachable from outside my network" are indistinguishable -
/// deliberately so, one setting screen covers both. User-requested
/// 2026-08-31.
///
/// One entry from [CloudLlmClient.fetchAvailableModels] - just the model id
/// plus whether the provider's own `pricing` data marks it as free to use.
/// [isFree] is best-effort: a provider that omits pricing information
/// entirely (e.g. plain OpenAI) always reports false here rather than
/// guessing - only OpenRouter is known to expose this per-model as of this
/// writing, which is exactly the case this was added for (2026-08-31 user
/// request: OpenRouter alone lists hundreds of models, several genuinely
/// free - worth calling out next to the name).
class CloudLlmModelInfo {
  final String id;
  final bool isFree;

  const CloudLlmModelInfo({required this.id, required this.isFree});

  /// What [SearchableSelectField.labelOf] shows in local_llm_settings_card.dart's
  /// Android model picker - the plain id, with "(gratuit)" appended only
  /// when [isFree].
  String get displayLabel => isFree ? '$id (gratuit)' : id;
}

/// Strips a reasoning model's internal chain-of-thought from [text] before
/// it ever reaches [LlmResponse] - defense in depth alongside the
/// `'reasoning': {'exclude': true}` request field [CloudLlmClient._chat]
/// already sends, for a provider/model that only partially honors that flag
/// and still wraps its narration in the (fairly standard across reasoning
/// models) `<think>...</think>` tags. Only ever removes a *complete*
/// `<think>...</think>` block - an *unterminated* one (the model's
/// generation got cut off by `max_tokens` while still "thinking", so no
/// closing tag ever arrives) is left alone rather than guessed at, since
/// there's no reliable way to tell where reasoning ends and a real answer
/// might have started; [maxTokens] being raised well above what reasoning
/// alone should need (see call sites) is the actual fix for that case, this
/// is just cleanup for the well-formed one.
String _stripReasoning(String text) {
  final stripped = text
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  return stripped;
}

/// Reuses [intentSystemPrompt]/[freeformSystemPrompt] verbatim rather than
/// duplicating them - the model behind this client only ever sees the same
/// carefully-tuned instructions [LlamaServerClient] already uses, so
/// switching backend never changes what's actually being asked.
class CloudLlmClient implements LlmEngine {
  /// No trailing slash, includes any version segment the provider needs -
  /// e.g. "https://api.openai.com/v1", "https://api.mistral.ai/v1", or
  /// "https://bteuile.ddns.net:8793/v1" for a llama-server started with
  /// `--api-key` and reachable the same way the web app itself already is
  /// (see CLAUDE.md's DDNS/port-forward note).
  final String baseUrl;

  /// Sent as `Authorization: Bearer <apiKey>` - bring-your-own-key: this
  /// app never bundles or proxies a key of its own, the user pays their
  /// own provider directly (or secures their own llama-server with one).
  final String apiKey;

  final String model;
  final http.Client _client;

  @override
  int maxTokens = 2048;

  CloudLlmClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  }) : _client = http.Client();

  Uri get _endpoint => Uri.parse('$baseUrl/chat/completions');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

  /// One-shot, never-polling health check - backs Settings' "Tester la
  /// connexion" button, same never-throws contract as
  /// [LlamaServerClient.healthCheck]: true only on a successful response,
  /// false on anything else (wrong key, wrong URL/model, unreachable).
  /// Uses a real (near-free, `max_tokens: 1`) chat request rather than a
  /// GET - unlike llama-server, an arbitrary OpenAI-compatible provider
  /// isn't guaranteed to expose an unauthenticated `/health`-style route,
  /// but every one of them has to implement the one endpoint this app
  /// actually needs.
  Future<bool> healthCheck() async {
    try {
      final response = await _client.post(
        _endpoint,
        headers: _headers,
        body: jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': 'ping'}
          ],
          'max_tokens': 1,
        }),
      ).timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Lists models available for [apiKey] on this provider, via the standard
  /// OpenAI-compatible `GET /v1/models` endpoint - implemented by every
  /// provider this client realistically targets (OpenAI, Mistral, Groq,
  /// OpenRouter, and llama-server's own OpenAI-compatible mode). Backs
  /// Settings' "Charger la liste des modèles" button (2026-08-31, user
  /// request: OpenRouter alone lists hundreds of models, typing an exact ID
  /// from memory isn't realistic) - lets the user pick from what their key
  /// can actually use instead. Free models first (2026-08-31 user request),
  /// then alphabetically by id within each group, for a stable, scannable
  /// list; throws on any failure (wrong URL/key, unreachable,
  /// unexpected response shape) rather than returning an empty list, so the
  /// caller can tell "genuinely zero models" apart from "the request itself
  /// failed".
  ///
  /// [CloudLlmModelInfo.isFree] reads each entry's own `pricing` object
  /// (OpenRouter's shape: `{"prompt": "0", "completion": "0", ...}`, string-
  /// encoded per-token USD cost) - free only when both prompt and
  /// completion cost parse to exactly zero. A provider whose response has
  /// no `pricing` field at all (plain OpenAI, Mistral, a self-hosted
  /// llama-server) always reports false here, never guessed.
  Future<List<CloudLlmModelInfo>> fetchAvailableModels() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/models'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Le service a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final data = decoded['data'] as List?;
    if (data == null) return [];
    final models = <CloudLlmModelInfo>[];
    for (final entry in data) {
      if (entry is! Map<String, dynamic>) continue;
      final id = entry['id'] as String?;
      if (id == null) continue;
      final pricing = entry['pricing'] as Map<String, dynamic>?;
      final promptCost = double.tryParse('${pricing?['prompt']}');
      final completionCost = double.tryParse('${pricing?['completion']}');
      final isFree =
          pricing != null && promptCost == 0 && completionCost == 0;
      models.add(CloudLlmModelInfo(id: id, isFree: isFree));
    }
    models.sort((a, b) {
      if (a.isFree != b.isFree) return a.isFree ? -1 : 1;
      return a.id.compareTo(b.id);
    });
    return models;
  }

  /// [tokensPerSecond] comes from the standard OpenAI `usage.completion_tokens`
  /// field (a real generated-token count every provider this client targets
  /// reports) divided by wall-clock elapsed time measured around the
  /// request - there's no server-side timing in this API shape the way
  /// llama.cpp's own `/completion` response includes. Null (never
  /// estimated) whenever `usage`/`completion_tokens` is missing.
  ///
  /// [onChunk] switches this to a real streaming request (`'stream': true`)
  /// - see [LlmEngine.ask]'s own doc comment. Also flips `'reasoning':
  /// {'exclude'}` to `false`: with nobody watching live, hidden reasoning
  /// is pure waste to ask for (the non-streaming path below still excludes
  /// it), but once [onChunk] exists there's finally somewhere to show it.
  Future<LlmResponse> _chat({
    required String systemPrompt,
    required String question,
    required double temperature,
    required int maxTokens,
    bool jsonMode = false,
    LlmChunkCallback? onChunk,
  }) {
    return onChunk == null
        ? _chatOnce(
            systemPrompt: systemPrompt,
            question: question,
            temperature: temperature,
            maxTokens: maxTokens,
            jsonMode: jsonMode,
          )
        : _chatStreamed(
            systemPrompt: systemPrompt,
            question: question,
            temperature: temperature,
            maxTokens: maxTokens,
            jsonMode: jsonMode,
            onChunk: onChunk,
          );
  }

  Map<String, Object?> _requestBody({
    required String systemPrompt,
    required String question,
    required double temperature,
    required int maxTokens,
    required bool jsonMode,
    required bool excludeReasoning,
    required bool stream,
  }) =>
      {
        'model': model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': question},
        ],
        'temperature': temperature,
        'max_tokens': maxTokens,
        // Standard OpenAI field, implemented (or safely ignored) by every
        // provider this client realistically targets - meaningfully
        // improves reliability of the JSON-only responses ([ask]/
        // [askWithSystemPrompt]) over relying on the system prompt's own
        // "réponds UNIQUEMENT avec un objet JSON" instruction alone, the
        // way llama.cpp's GBNF grammar does for [LlamaServerClient].
        if (jsonMode) 'response_format': {'type': 'json_object'},
        // OpenRouter's extension for reasoning-capable models (many of its
        // free models, including the one behind the 2026-09-01 user report
        // below, "think out loud" by default) - asks the provider to leave
        // that internal narration out of `content` entirely when nothing's
        // watching live ([excludeReasoning] true, the non-streaming path).
        // Ignored (harmlessly, as an unrecognized field) by every other
        // provider/a non-reasoning model - never errors, confirmed against
        // OpenAI/llama-server's own OpenAI-compatible mode.
        'reasoning': {'exclude': excludeReasoning},
        if (stream) 'stream': true,
        // Without this, OpenAI-compatible streaming responses omit `usage`
        // entirely (it's opt-in), so [_chatStreamed] would never learn a
        // real token count/split at all - see [LlmResponse]'s own doc
        // comment on never inventing one instead.
        if (stream) 'stream_options': {'include_usage': true},
      };

  /// See [LlmResponse.reasoningTokens]'s own doc comment - the standard
  /// OpenAI-compatible `usage.completion_tokens_details.reasoning_tokens`
  /// field, present only when the provider actually reports this split.
  static int? _reasoningTokens(Map<String, dynamic>? usage) {
    final details = usage?['completion_tokens_details'] as Map<String, dynamic>?;
    return details?['reasoning_tokens'] as int?;
  }

  Future<LlmResponse> _chatOnce({
    required String systemPrompt,
    required String question,
    required double temperature,
    required int maxTokens,
    required bool jsonMode,
  }) async {
    final stopwatch = Stopwatch()..start();
    final response = await _client.post(
      _endpoint,
      headers: _headers,
      body: jsonEncode(_requestBody(
        systemPrompt: systemPrompt,
        question: question,
        temperature: temperature,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        excludeReasoning: true,
        stream: false,
      )),
    );
    stopwatch.stop();
    if (response.statusCode != 200) {
      throw StateError('Le service IA a répondu ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List?;
    final text = choices == null || choices.isEmpty
        ? ''
        : ((choices.first as Map<String, dynamic>)['message']
                as Map<String, dynamic>?)?['content'] as String? ??
            '';
    final usage = decoded['usage'] as Map<String, dynamic>?;
    final completionTokens = usage?['completion_tokens'] as int?;
    final elapsedMs = stopwatch.elapsedMilliseconds;
    final tps = (completionTokens != null && completionTokens > 0 && elapsedMs > 0)
        ? completionTokens / (elapsedMs / 1000)
        : null;
    return LlmResponse(_stripReasoning(text),
        tokensPerSecond: tps,
        completionTokens: completionTokens,
        reasoningTokens: _reasoningTokens(usage));
  }

  /// Server-Sent Events, OpenAI's standard streaming shape (and OpenRouter's
  /// own, which every free model this app targets goes through): repeated
  /// `data: {...}\n\n` lines, each a partial `choices[0].delta` (either
  /// `content` or, for a reasoning-capable model, a separate `reasoning`
  /// field - both handled, since which one a given provider actually uses
  /// varies), terminated by a literal `data: [DONE]` line. `content` still
  /// goes through [ThinkTagSplitter] too, on top of the separate `reasoning`
  /// field - a provider that inlines `<think>` tags in `content` instead of
  /// (or alongside) using the structured field is exactly the same
  /// non-compliant case [_stripReasoning] already defends against
  /// non-streamed, so both paths need the same defense.
  Future<LlmResponse> _chatStreamed({
    required String systemPrompt,
    required String question,
    required double temperature,
    required int maxTokens,
    required bool jsonMode,
    required LlmChunkCallback onChunk,
  }) async {
    final stopwatch = Stopwatch()..start();
    final request = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode(_requestBody(
        systemPrompt: systemPrompt,
        question: question,
        temperature: temperature,
        maxTokens: maxTokens,
        jsonMode: jsonMode,
        excludeReasoning: false,
        stream: true,
      ));
    final streamed = await _client.send(request);
    if (streamed.statusCode != 200) {
      throw StateError('Le service IA a répondu ${streamed.statusCode}.');
    }
    final answerBuffer = StringBuffer();
    final splitter = ThinkTagSplitter();
    int? completionTokens;
    int? reasoningTokens;
    void emitContent(String delta) {
      for (final (text, isReasoning) in splitter.feed(delta)) {
        if (!isReasoning) answerBuffer.write(text);
        onChunk(text, isReasoning);
      }
    }

    await for (final line in streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      final Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue; // a malformed/partial SSE line - skip rather than crash
      }
      final choices = chunk['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final delta = (choices.first as Map<String, dynamic>)['delta']
            as Map<String, dynamic>?;
        final reasoningDelta = delta?['reasoning'] as String?;
        if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
          onChunk(reasoningDelta, true);
        }
        final contentDelta = delta?['content'] as String?;
        if (contentDelta != null && contentDelta.isNotEmpty) {
          emitContent(contentDelta);
        }
      }
      final usage = chunk['usage'] as Map<String, dynamic>?;
      if (usage != null) {
        completionTokens = usage['completion_tokens'] as int?;
        reasoningTokens = _reasoningTokens(usage);
      }
    }
    for (final (text, isReasoning) in splitter.finish()) {
      if (!isReasoning) answerBuffer.write(text);
      onChunk(text, isReasoning);
    }
    stopwatch.stop();
    final elapsedMs = stopwatch.elapsedMilliseconds;
    final tokens = completionTokens;
    final tps = (tokens != null && tokens > 0 && elapsedMs > 0)
        ? tokens / (elapsedMs / 1000)
        : null;
    return LlmResponse(answerBuffer.toString(),
        tokensPerSecond: tps,
        completionTokens: completionTokens,
        reasoningTokens: reasoningTokens);
  }

  @override
  Future<LlmResponse> ask(String question, {LlmChunkCallback? onChunk}) => _chat(
        systemPrompt: intentSystemPrompt,
        question: question,
        temperature: 0.1,
        maxTokens: maxTokens,
        jsonMode: true,
        onChunk: onChunk,
      );

  @override
  Future<LlmResponse> askFreeform(String question, {LlmChunkCallback? onChunk}) =>
      _chat(
        systemPrompt: freeformSystemPrompt,
        question: question,
        temperature: 0.7,
        // [maxTokens] (see LlmEngine's own doc comment) is the belt and
        // suspenders against a reasoning model's hidden narration eating
        // the whole budget before a real answer ever appears, on top of
        // the 'reasoning': {'exclude': true} flag below (2026-09-01 user
        // report: some providers only partially honor that flag).
        maxTokens: maxTokens,
        onChunk: onChunk,
      );

  @override
  Future<LlmResponse> askWithSystemPrompt(String systemPrompt, String question,
          {LlmChunkCallback? onChunk}) =>
      _chat(
        systemPrompt: systemPrompt,
        question: question,
        temperature: 0.1,
        maxTokens: maxTokens,
        jsonMode: true,
        onChunk: onChunk,
      );

  @override
  Future<LlmResponse> askFreeformWithSystemPrompt(
          String systemPrompt, String question,
          {LlmChunkCallback? onChunk}) =>
      _chat(
        systemPrompt: systemPrompt,
        question: question,
        temperature: 0.2,
        maxTokens: maxTokens,
        onChunk: onChunk,
      );

  @override
  void close() => _client.close();
}
