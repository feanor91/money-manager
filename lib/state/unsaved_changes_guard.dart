import 'unsaved_changes_guard_stub.dart'
    if (dart.library.js_interop) 'unsaved_changes_guard_web.dart' as impl;

/// Warns the user - via the browser's own native "leave site? changes may
/// not be saved" prompt - before closing the tab/window while
/// [hasPendingWrite] would return true. See
/// DatabaseProvider.hasPendingWrite for exactly what that covers (a
/// debounced write not yet started, or one already in flight).
///
/// A no-op on any non-web platform: nothing to intercept there. This is
/// specifically a web problem - closing a browser tab tears down the page's
/// whole JS execution instantly, killing a pending Timer or an in-flight
/// Future with no chance to finish; a native app process being closed
/// doesn't behave the same way, and desktop/Android don't have this
/// debounced-write-to-a-separate-file design in the first place (see
/// mmex_database_web.dart's own doc comment on why web needs it at all).
///
/// Deliberately can only *warn*, never guarantee the save completes: even
/// inside a `beforeunload` handler, browsers do not wait for async work
/// (our write is a chain of promises - createWritable/write/close) to
/// finish before tearing the page down if the user chooses to leave anyway.
void registerUnsavedChangesGuard(bool Function() hasPendingWrite) =>
    impl.registerUnsavedChangesGuard(hasPendingWrite);
