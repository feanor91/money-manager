import 'package:llama_cpp_dart/llama_cpp_dart.dart';

/// Only ever imported from local_llm_manager_io.dart, itself only reached
/// after that file's own `Platform.isWindows` gate - see CLAUDE.md's
/// conditional-import-shell rule (this file pulls in `package:llama_cpp_dart`,
/// which pulls in `dart:ffi`, so it must never be importable from anything
/// that also compiles for web).
///
/// UNTESTED beyond `flutter analyze`/compiling: written from a Linux
/// container with no Windows machine, no compatible native library, and no
/// way to actually run a completion end-to-end. The Dart-level API calls
/// here were checked against llama_cpp_dart 0.2.2's real source (see
/// ROADMAP.md), but real verification - does loading succeed, does the
/// grammar actually constrain output, is the JSON usable - can only happen
/// on a real Windows machine with the native runtime in place. Every
/// failure path here is designed to return null/rethrow so the caller
/// (local_llm_manager_io.dart) always has a safe fallback to the
/// rule-based parser.

/// Standard llama.cpp JSON grammar (GBNF) - constrains sampling so the
/// model can only ever produce syntactically valid JSON, never prose or a
/// broken partial object. Deliberately not narrowed to this app's exact
/// intent schema (hand-writing that reliably in GBNF wasn't practical to
/// verify without a Windows machine to test against) - see
/// intent_json_codec.dart for the schema/semantic validation that happens
/// after decoding.
const _jsonGrammar = r'''
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

- "kind" doit être exactement l'une de ces valeurs : expenseTotal, incomeTotal, incomeVsExpense, balance, topExpenses, payeeSpend.
- "period" est la portion de la question qui décrit une période (ex: "juillet 2026", "le mois dernier", "cette année"), ou null si aucune n'est mentionnée.
- "category", "account", "payee" sont les noms mentionnés dans la question (ou null s'ils ne sont pas mentionnés) - recopie seulement ce que dit la question, n'en invente jamais.
- "topN" est un nombre si la question en demande un (ex: "top 10"), sinon null.
N'invente jamais de montant ni de date précise : ce sont d'autres calculs qui s'en chargent, pas toi.
''';

/// Wraps one loaded model in a background isolate (llama_cpp_dart's
/// `LlamaParent` - see its doc/isolate.md) so inference never blocks the UI
/// thread. One [LlamaEngine] per loaded model; call [dispose] before
/// loading a different model or when local AI is disabled.
class LlamaEngine {
  final LlamaParent _parent;

  LlamaEngine._(this._parent);

  static Future<LlamaEngine> load(String modelPath, {required String libraryPath}) async {
    Llama.libraryPath = libraryPath;
    final sampler = SamplerParams()
      ..temp = 0.1
      ..grammarStr = _jsonGrammar
      ..grammarRoot = 'root';
    final loadCommand = LlamaLoad(
      path: modelPath,
      // CPU-only: no way to verify a GPU path (driver, VRAM budget) works
      // without hands-on access to the real machine - CPU is slower but
      // never silently fails to find a GPU it can't actually use.
      modelParams: ModelParams()..nGpuLayers = 0,
      contextParams: ContextParams()..nCtx = 4096,
      samplingParams: sampler,
    );
    final parent = LlamaParent(loadCommand, ChatMLFormat());
    await parent.init();
    return LlamaEngine._(parent);
  }

  /// Runs a single, stateless question through the model (this app never
  /// keeps a multi-turn chat history - each question is answered fresh)
  /// and returns its raw text response, for intent_json_codec.dart to
  /// decode. Never throws on a generation failure other than propagating
  /// it - the caller (local_llm_manager_io.dart) is responsible for
  /// catching and falling back to the rule-based parser.
  Future<String> ask(String question) async {
    _parent.messages = [
      {'role': 'system', 'content': _systemPrompt},
      {'role': 'user', 'content': question},
    ];
    final buffer = StringBuffer();
    final subscription = _parent.stream.listen(buffer.write);
    try {
      final promptId = await _parent.sendPrompt(question);
      await _parent.waitForCompletion(promptId);
    } finally {
      await subscription.cancel();
    }
    return buffer.toString();
  }

  Future<void> dispose() => _parent.dispose();
}
