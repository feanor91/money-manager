/// One model response - the raw text plus, when the backend's own response
/// actually reports real generated-token counts, the throughput computed
/// from them. Every count here is null whenever the backend didn't report
/// it (never estimated from character count or any other proxy - this
/// app's standing rule is to never invent a number, see CLAUDE.md/the SQL
/// system prompt's own "jamais de chiffre inventé"). Backs Settings'
/// nowhere, but nl_query_dialog.dart's answer bubbles show these as a
/// small caption (2026-08-31 user request, extended 2026-09-10 to split
/// reasoning from answer tokens) when present.
class LlmResponse {
  final String text;
  final double? tokensPerSecond;

  /// Total generated tokens for this call (reasoning + answer combined) -
  /// OpenRouter/OpenAI's `usage.completion_tokens`, or llama.cpp's own
  /// `tokens_predicted`. [tokensPerSecond] is computed from this one, not
  /// from [reasoningTokens]/[answerTokens] separately.
  final int? completionTokens;

  /// The portion of [completionTokens] spent on hidden reasoning before
  /// the real answer - only ever non-null when the backend actually
  /// reports this split (OpenAI-compatible `usage.completion_tokens_
  /// details.reasoning_tokens`, sent by some OpenRouter providers for a
  /// reasoning-capable model). llama.cpp's `/completion` API has no such
  /// concept at all, so this is always null there - never derived from
  /// [ThinkTagSplitter]'s own reasoning/answer character split, since a
  /// character count isn't a token count and guessing one would violate
  /// the "never invent a number" rule above.
  final int? reasoningTokens;

  /// [completionTokens] minus [reasoningTokens] when both are known - the
  /// tokens actually spent on the visible answer. Null whenever either
  /// input is null (nothing to subtract from/with).
  int? get answerTokens {
    final total = completionTokens;
    final reasoning = reasoningTokens;
    return (total == null || reasoning == null) ? null : total - reasoning;
  }

  const LlmResponse(this.text,
      {this.tokensPerSecond, this.completionTokens, this.reasoningTokens});
}

/// Common contract implemented by every "ask a model something" backend -
/// [LlamaServerClient] (llama_server_client.dart, talking to a locally-run
/// or remote llama.cpp server's native `/completion` API) and
/// [CloudLlmClient] (cloud_llm_client.dart, talking to any OpenAI-compatible
/// `/v1/chat/completions` endpoint - a real hosted provider or the user's
/// own PC reached remotely). sql_query_engine.dart's `answerViaFullSqlAccess`
/// and local_llm_manager_io.dart/local_llm_manager_web.dart's `_ensureEngine`
/// only ever need these four calls, so this is the whole surface either
/// backend must provide - everything else (auth, request shape, model
/// selection) is each implementation's own business.
abstract class LlmEngine {
  /// The single `max_tokens`/`n_predict` ceiling sent on *every* call this
  /// engine makes (intent extraction, SQL writing, answer phrasing, free
  /// conversation alike) - replaces an earlier per-call-shape hardcoded set
  /// of values (256/512/1024/2048/4096) that a 2026-09-10 user report
  /// called out as confusing once a "multiply everything" slider sat on top
  /// of them ("c'est y fois de quoi? ... si on ne connaît pas le max
  /// token..."): one plain, visible number is simpler to reason about than
  /// several invisible base values times a ratio, even though a tiny
  /// intent-extraction JSON object doesn't strictly need as much room as a
  /// long free-form answer - harmless slack, not a real cost, since this is
  /// a ceiling the model stops well short of unless something's already
  /// gone wrong (see [CloudLlmClient.defaultCloudLlmModel]'s own doc
  /// comment on why a reasoning model's hidden narration can hit it).
  /// Defaults to 2048 (this app's historical middle-of-the-road value for
  /// the SQL-writing call). Settable both from Settings
  /// (local_llm_settings_card.dart, the persistent default) and from
  /// "Poser une question"'s own slider (nl_query_dialog.dart, a quick
  /// per-session override) - both read/write the exact same stored value
  /// (see [local_llm_manager.dart]'s `llmMaxTokens`/`setLlmMaxTokens`), so
  /// there is only ever one number to keep straight. Each manager
  /// (local_llm_manager_io.dart/_web.dart) stamps the current value onto
  /// every [LlmEngine] it hands out, cached or freshly built, so a change
  /// takes effect on the very next question - never baked into the
  /// cached-client-rebuild config tuples, deliberately, since a mutable
  /// field read fresh per request is simpler than forcing a server
  /// restart/client rebuild just to change this.
  ///
  /// Declared as an abstract getter/setter (not a concrete field) because
  /// every implementer here uses `implements LlmEngine`, not `extends` - an
  /// `implements` clause only borrows the interface, never a concrete
  /// field's storage/initializer, so each concrete class needs its own
  /// backing field satisfying this contract.
  int get maxTokens;
  set maxTokens(int value);

  /// `onChunk` (2026-09-10 user request: "afficher en temps réel... ce que
  /// fait le modèle", like a standard AI chat's own "thinking" panel) -
  /// when given, each call switches to a real streaming HTTP request and
  /// invokes this once per newly-arrived piece of text, tagged
  /// [isReasoning] true for a model's own internal chain-of-thought
  /// (llama.cpp: inline `<think>` tags, the only mechanism it has - see
  /// [ThinkTagSplitter]; OpenRouter: either that same inline convention or
  /// its own separate `reasoning` delta field, whichever the provider
  /// actually uses) and false for the real answer. The eventually-returned
  /// [LlmResponse.text] is unaffected either way - still just the clean,
  /// reasoning-stripped final text, exactly as a non-streaming call would
  /// return, so every existing caller (JSON parsing, SQL execution) stays
  /// correct without needing to know or care whether streaming happened.
  /// Omitted (null, the default), every method behaves exactly as before
  /// this parameter existed - a single plain non-streaming request.
  Future<LlmResponse> ask(String question, {LlmChunkCallback? onChunk});
  Future<LlmResponse> askFreeform(String question, {LlmChunkCallback? onChunk});
  Future<LlmResponse> askWithSystemPrompt(String systemPrompt, String question,
      {LlmChunkCallback? onChunk});
  Future<LlmResponse> askFreeformWithSystemPrompt(
      String systemPrompt, String question,
      {LlmChunkCallback? onChunk});
  void close();
}

/// See [LlmEngine.ask]'s own doc comment on `onChunk`.
typedef LlmChunkCallback = void Function(String text, bool isReasoning);

/// The result of [askLocalLlmFreeform] - three distinct outcomes, not just
/// success/null, so nl_query_dialog.dart can tell "the AI is unavailable/
/// disabled" and "nothing recognized this as a financial question, and the
/// AI genuinely had nothing to add" (both silent, fall through to the
/// generic "not understood" message, same as before this type existed)
/// apart from "the AI was configured and reachable but the call itself
/// failed" (2026-08-31 user report: a rate-limited cloud provider silently
/// produced "je n'ai pas compris cette question", which is actively
/// misleading - the AI never got a chance to understand anything).
///
/// [LlmFreeformOutcome.error]'s [message] is only ever a short, already-
/// user-safe description (an HTTP status, "connexion impossible" - see
/// each backend's own `StateError` text) - never a raw exception `toString()`,
/// which could leak an internal stack/type name into the chat transcript.
sealed class LlmFreeformOutcome {
  const LlmFreeformOutcome();
}

class LlmFreeformSuccess extends LlmFreeformOutcome {
  final String text;
  final double? tokensPerSecond;

  /// See [LlmResponse]'s own doc comment on all three - carried through
  /// unchanged from the [LlmResponse] this outcome was built from.
  final int? completionTokens;
  final int? reasoningTokens;

  const LlmFreeformSuccess(this.text,
      {this.tokensPerSecond, this.completionTokens, this.reasoningTokens});
}

/// Not usable at all right now (unsupported platform, disabled, no engine
/// configured) - nothing went wrong, there's just nothing to report.
class LlmFreeformUnavailable extends LlmFreeformOutcome {
  const LlmFreeformUnavailable();
}

/// The engine was reachable but the call itself failed - see this class's
/// own doc comment above for why this is told apart from
/// [LlmFreeformUnavailable].
class LlmFreeformError extends LlmFreeformOutcome {
  final String message;
  const LlmFreeformError(this.message);
}
