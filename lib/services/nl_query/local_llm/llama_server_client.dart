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
{"kind": "...", "period": "...", "category": "...", "account": "...", "payee": "...", "topN": ...}

- "kind" doit être exactement l'une de ces valeurs : expenseTotal, incomeTotal, incomeVsExpense, balance, topExpenses, payeeSpend, outlook.
- "period" est la portion de la question qui décrit une période (ex: "juillet 2026", "le mois dernier", "cette année"), ou null si aucune n'est mentionnée.
- "category", "account", "payee" sont les noms mentionnés dans la question (ou null s'ils ne sont pas mentionnés) - recopie seulement ce que dit la question, n'en invente jamais.
- "topN" est un nombre si la question en demande un (ex: "top 10"), sinon null.
N'invente jamais de montant ni de date précise : ce sont d'autres calculs qui s'en chargent, pas toi.
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

/// Talks HTTP to whatever's already listening on 127.0.0.1:[port] -
/// entirely unaware of whether that's a real `llama-server.exe` process or
/// (in tests) a fake stand-in; spawning/killing the real process is
/// local_llm_manager_io.dart's job, not this class's.
class LlamaServerClient {
  final int port;
  final http.Client _client;

  LlamaServerClient(this.port) : _client = http.Client();

  /// Polls `/health` until it answers 200, or throws once [timeout]
  /// elapses - a large model can genuinely take a while to load on CPU
  /// (see local_llm_manager_io.dart's rationale for staying CPU-only: no
  /// way to verify a GPU path works without hands-on access to the real
  /// machine). [hasExited] lets the caller report "the process already
  /// died" so this can fail fast instead of waiting out the full timeout
  /// polling a port nothing will ever answer on again.
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
            .get(Uri.parse('http://127.0.0.1:$port/health'))
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
      Uri.parse('http://127.0.0.1:$port/completion'),
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

  void close() => _client.close();
}

bool _neverExited() => false;
