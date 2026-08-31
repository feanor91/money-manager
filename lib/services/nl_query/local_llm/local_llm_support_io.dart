import 'dart:io';

/// Windows: full local-model support (see local_llm_manager_io.dart).
/// Android (2026-08-31): cloud-only support - the phone talks to an
/// external OpenAI-compatible endpoint instead of running anything itself,
/// see local_llm_manager_io.dart's Android branch and
/// local_llm_settings_card.dart's Android-only card variant.
bool get isLocalLlmSupported => Platform.isWindows || Platform.isAndroid;
