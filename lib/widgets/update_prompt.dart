import 'package:flutter/material.dart';

import 'update_prompt_stub.dart'
    if (dart.library.io) 'update_prompt_io.dart' as impl;

/// Silently checks GitHub for a newer release and, if one exists, offers to
/// download and install it - Windows desktop and Android (confirmed working
/// live 2026-08-04, see ROADMAP.md); web has nothing to install, so this is
/// a no-op there. Safe to call unconditionally from any platform: never
/// throws, and a failed or slow check runs in the background without
/// blocking startup.
Future<void> checkForUpdatesAndPrompt(BuildContext context) =>
    impl.checkForUpdatesAndPrompt(context);
