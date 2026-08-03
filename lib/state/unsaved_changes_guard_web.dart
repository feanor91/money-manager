import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Only ever imported from unsaved_changes_guard.dart, itself only reached
/// via that file's conditional import - see CLAUDE.md's conditional-import-
/// shell rule (this file touches `package:web`, which has no reason to
/// exist outside the web target).
void registerUnsavedChangesGuard(bool Function() hasPendingWrite) {
  web.window.onbeforeunload = ((web.Event event) {
    if (!hasPendingWrite()) return;
    // Best practice per MDN (see BeforeUnloadEvent.returnValue's own doc
    // comment in package:web): preventDefault() is the modern trigger,
    // returnValue is set alongside it for older engines that only look at
    // that. Neither actually pauses the unload if the user confirms
    // leaving anyway - browsers never wait out an in-flight async write.
    event.preventDefault();
    (event as web.BeforeUnloadEvent).returnValue = 'unsaved';
  }).toJS;
}
