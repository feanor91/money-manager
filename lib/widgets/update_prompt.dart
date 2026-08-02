import 'package:flutter/material.dart';

import 'update_prompt_stub.dart'
    if (dart.library.io) 'update_prompt_io.dart' as impl;

/// Silently checks GitHub for a newer release and, if one exists, offers to
/// download and install it - Windows desktop only for now (web has nothing
/// to install; Android needs its own native install-trigger, not yet built
/// - see ROADMAP.md). Safe to call unconditionally from any platform: never
/// throws, and a failed or slow check runs in the background without
/// blocking startup.
Future<void> checkForUpdatesAndPrompt(BuildContext context) =>
    impl.checkForUpdatesAndPrompt(context);
