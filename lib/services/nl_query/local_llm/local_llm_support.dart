import 'local_llm_support_stub.dart' if (dart.library.io) 'local_llm_support_io.dart' as impl;

/// True only on Windows desktop - the only platform this optional local-AI
/// layer targets (see CLAUDE.md and ROADMAP.md). Kept in its own tiny
/// shell, separate from local_llm_manager.dart, so any file that just needs
/// to decide whether to *show* the feature (settings_screen.dart,
/// nl_query_dialog.dart) doesn't have to pull in the download/inference
/// machinery merely to ask this question.
bool get isLocalLlmSupported => impl.isLocalLlmSupported;
