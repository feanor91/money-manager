/// One model response - the raw text plus, when the backend's own response
/// actually reports a real generated-token count, the throughput computed
/// from it. [tokensPerSecond] is null whenever that count isn't available
/// (never estimated from character count or any other proxy - this app's
/// standing rule is to never invent a number, see CLAUDE.md/the SQL system
/// prompt's own "jamais de chiffre inventé"). Backs Settings' nowhere, but
/// nl_query_dialog.dart's answer bubbles show it as a small caption
/// (2026-08-31 user request) when present.
class LlmResponse {
  final String text;
  final double? tokensPerSecond;

  const LlmResponse(this.text, {this.tokensPerSecond});
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
  Future<LlmResponse> ask(String question);
  Future<LlmResponse> askFreeform(String question);
  Future<LlmResponse> askWithSystemPrompt(String systemPrompt, String question);
  Future<LlmResponse> askFreeformWithSystemPrompt(
      String systemPrompt, String question);
  void close();
}

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
  const LlmFreeformSuccess(this.text, {this.tokensPerSecond});
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
