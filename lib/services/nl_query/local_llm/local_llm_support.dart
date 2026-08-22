import 'local_llm_support_stub.dart'
    if (dart.library.js_interop) 'local_llm_support_web.dart'
    if (dart.library.io) 'local_llm_support_io.dart' as impl;

/// True on Windows desktop AND on web - web's version talks HTTP to a
/// llama.cpp server the user runs themselves on their PC (the browser
/// can't load a multi-gigabyte model, but it can talk to one over the
/// network - see local_llm_manager_web.dart). Kept in its own tiny shell,
/// separate from local_llm_manager.dart, so any file that just needs to
/// decide whether to *show* the feature (settings_screen.dart,
/// nl_query_dialog.dart) doesn't have to pull in the download/inference
/// machinery merely to ask this question.
bool get isLocalLlmSupported => impl.isLocalLlmSupported;
