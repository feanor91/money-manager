import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/db_picker_screen.dart';
import 'screens/home_shell.dart';
import 'screens/pin_lock_screen.dart';
import 'screens/settings_screen.dart';
import 'services/notifications/sync_notification_service.dart';
import 'state/database_provider.dart';
import 'state/pin_lock_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/update_prompt.dart';

/// MaterialApp's own internal Navigator - only actually mounted once the
/// PIN gate reaches `none`/`unlocked` (see _PinGateState.build), so the
/// update check only falls back to this key in that specific branch. While
/// the database-picker/PIN screen is still showing, the check instead uses
/// a context from within _gated's own route builder - see
/// _PinGateState._maybeCheckForUpdates's doc comment for why relying on
/// this key alone silently broke the check entirely for a day.
final rootNavigatorKey = GlobalKey<NavigatorState>();

class MoneyManagerApp extends StatelessWidget {
  const MoneyManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Watched (not just read) so a palette/theme-mode change in Settings -
    // which calls AppTheme.applyPalette then notifyListeners - rebuilds
    // MaterialApp with the new accent/brightness immediately, without
    // needing to thread that state through every individual screen.
    final dbProvider = context.watch<DatabaseProvider>();
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Money Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: dbProvider.themeMode,
      // Toute l'UI est en francais en dur (voir ROADMAP.md) - le picker de
      // date Material (showDatePicker) suit sa propre localisation
      // independante du texte de l'appli, d'ou ce reglage explicite.
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Kept only so a stale bookmarked/history "/settings" URL from before
      // this fix still resolves to something rather than a blank/error
      // route - normal in-app navigation no longer uses it (see
      // dashboard_screen.dart, a plain MaterialPageRoute push like every
      // other screen). Never reachable unprotected either way: see
      // [builder] below.
      routes: {
        '/settings': (_) => const SettingsScreen(),
      },
      home: const HomeShell(),
      // Wraps *every* route this MaterialApp ever builds - home, "/settings",
      // or any future one - not just "/". This is deliberate: on web, a
      // browser refresh while the address bar shows a named route (e.g.
      // "/settings") rebuilds the app starting directly at that route,
      // bypassing `home` entirely. A gate that only lived at `home` (as a
      // wrapper `_RootGate` widget once did here) would only ever run for
      // the "/" route, silently skipping the PIN/database check on any
      // other URL - confirmed 2026-07-31: refreshing on Paramètres reopened
      // it without asking for the PIN, while refreshing elsewhere correctly
      // did. Putting the gate in `builder` instead makes it structurally
      // impossible for any current or future route to bypass it.
      builder: (context, child) => _PinGate(child: child),
    );
  }
}

/// Shows the PIN screen while locked, the database picker until a database
/// is loaded, then whatever route was actually requested - in that order,
/// so the PIN gate is checked before anything about the database (or its
/// content) is ever shown, regardless of which route triggered this build.
class _PinGate extends StatefulWidget {
  final Widget? child;

  const _PinGate({required this.child});

  @override
  State<_PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<_PinGate> with WidgetsBindingObserver {
  bool _updateCheckStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Starts the update check as soon as *any* screen with a real
  /// Navigator/Overlay ancestor is showing - the database-picker/PIN
  /// screen, not just after a full unlock (2026-08-07, user request: check
  /// before being asked for the PIN). Guarded to run at most once per app
  /// session regardless of which caller gets there first.
  ///
  /// **Not `rootNavigatorKey.currentContext` alone, found 2026-08-07
  /// breaking this the same day it shipped**: that key is attached to
  /// `widget.child` (MaterialApp's own routed Navigator, built from
  /// `home:`), which [build] only ever returns once
  /// `PinGateStatus.none`/`unlocked` - i.e. exactly *after* the PIN gate
  /// this feature is supposed to run *before*. While the db-picker/PIN
  /// screen is showing, `build` returns `_gated(...)`'s own separate
  /// Navigator instead, so `rootNavigatorKey.currentContext` was still
  /// `null` the one time this used to be tried (from `initState`, which
  /// never runs again) - the check silently never fired at all, for either
  /// platform. Fixed by calling this from within `_gated`'s own route
  /// builder too (see below), which always has Navigator/Overlay ancestry
  /// no matter which gate screen is on top.
  void _maybeCheckForUpdates(BuildContext context) {
    if (_updateCheckStarted) return;
    _updateCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) checkForUpdatesAndPrompt(context);
    });
  }

  /// Same as [_maybeCheckForUpdates], but for the `widget.child` branch of
  /// [build]: that widget (MaterialApp's own routed Navigator, keyed by
  /// [rootNavigatorKey]) hasn't actually mounted as an Element yet at the
  /// point [build] returns it, so there's no usable context to capture
  /// synchronously the way [_gated]'s route builder provides one - resolve
  /// [rootNavigatorKey]'s context lazily, after the frame that mounts it.
  void _maybeCheckForUpdatesViaRootNavigator() {
    if (_updateCheckStarted) return;
    _updateCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navContext = rootNavigatorKey.currentContext;
      if (navContext != null) checkForUpdatesAndPrompt(navContext);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock only on `paused` (mobile: home button, app switcher, incoming
    // call) - a PIN only checked once at launch wouldn't do much for a
    // phone left unlocked on a table. Deliberately excludes `inactive` and
    // `hidden`: on web those fire on every tab switch or transient focus
    // loss (alt-tab, opening dev tools, switching windows), which would
    // relock far too aggressively for a browser tab left open. `paused`
    // itself doesn't fire on web, so in practice the web app only ever
    // locks again after an actual page reload.
    if (state == AppLifecycleState.paused) {
      context.read<PinLockProvider>().lockOnBackground();
      // Push local edits out as soon as the user leaves, not just on the
      // *next* resume - user-requested 2026-08-04, symmetric with the
      // resume-triggered pull below. Best-effort only: Android can suspend
      // the process shortly after `paused` fires, so a slow upload isn't
      // guaranteed to finish (see SyncNotificationService's doc comment) -
      // this is a real improvement over "only on manual tap or next
      // resume", not a guarantee. Nobody's looking at the screen for this
      // one, so the in-app banner alone wouldn't be seen - a system
      // notification confirms it instead.
      unawaited(_syncInBackground(context.read<DatabaseProvider>()));
    } else if (state == AppLifecycleState.resumed) {
      // restoreLastDatabase() (main.dart) only runs once per process, at a
      // true cold start - on Android, switching away and back (the common
      // case; the OS keeps the process alive) never re-runs it, so without
      // this a WebDAV change made elsewhere could sit unpicked-up until the
      // user remembered to tap "Synchroniser maintenant" - confirmed
      // 2026-08-04 (desktop edit invisible on Android until a manual sync).
      // syncNow() already no-ops harmlessly off-Android/unconfigured, and
      // is safe to fire while the PIN screen is still showing (it only
      // touches DatabaseProvider state, not navigation). No notification
      // here - the user is looking at the screen as it resumes, so the
      // in-app banner (home_shell.dart's _SyncMessageBanner) already covers
      // it without needing a second, redundant channel.
      unawaited(context.read<DatabaseProvider>().syncNow());
    }
  }

  Future<void> _syncInBackground(DatabaseProvider dbProvider) async {
    await dbProvider.syncNow();
    final message = dbProvider.syncMessage;
    if (message != null) {
      await SyncNotificationService.showSyncMessage(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Database first: the PIN (and every other preference) now lives in
    // that database's own companion settings file, so there is nothing to
    // check the PIN gate against until a database is open - see
    // PinLockProvider.attachDatabase and CLAUDE.md.
    final dbProvider = context.watch<DatabaseProvider>();
    if (!dbProvider.isReady) {
      return _gated(const DbPickerScreen());
    }
    final pinLock = context.watch<PinLockProvider>();
    switch (pinLock.status) {
      case PinGateStatus.needsCompanionAccess:
        return _gated(const PinCompanionAccessScreen());
      case PinGateStatus.locked:
        return _gated(const PinUnlockScreen());
      case PinGateStatus.none:
      case PinGateStatus.unlocked:
        // Covers the (rarer) case where this is reached directly - no
        // database-picker/PIN screen ever showed via _gated below, e.g. a
        // database was already open and no PIN is configured - so the
        // check still fires exactly once even though _gated's own trigger
        // never got a chance to run first.
        _maybeCheckForUpdatesViaRootNavigator();
        return widget.child!;
    }
  }

  /// Wraps a gate substitute screen (shown *instead of* [widget.child] -
  /// i.e. instead of the Navigator MaterialApp itself already built) in its
  /// own single-route Navigator, so it has an Overlay ancestor of its own.
  ///
  /// Found 2026-08-04 diagnosing a PIN entry bug (desktop backspace-then-
  /// retype could resurrect deleted digits): without this, these screens sit
  /// directly in MaterialApp.builder's slot, entirely outside the real
  /// Navigator/Overlay `widget.child` represents. The instant PinUnlockScreen's
  /// autofocused field actually gained focus, EditableText's focus-changed
  /// handler tried to show selection handles via Overlay.of(context) and hit
  /// a null-check crash (no Overlay ancestor exists) - confirmed via a
  /// debug-logged real run: initState → one build() → the crash's stack
  /// trace (Overlay.of → SelectionOverlay.showHandles →
  /// TextSelectionOverlay.showHandles → EditableTextState.
  /// _handleSelectionChanged/_handleFocusChanged) → then dozens of build()
  /// calls in ~200ms as the framework tried to recover. That crash happening
  /// mid-way through EditableText's own focus/selection bookkeeping is what
  /// left it in a state where later backspace/retype edits could desync -
  /// not a bug in the PIN field's own code at all (an isolated clone of its
  /// exact TextField/FocusNode setup, still properly nested under a normal
  /// Navigator, never reproduced the issue). DbPickerScreen/
  /// PinCompanionAccessScreen never surfaced this only because neither
  /// happens to autofocus a text field - they were silently exposed to the
  /// exact same missing-Overlay condition the whole time.
  ///
  /// **`key: ValueKey(child.runtimeType)` is load-bearing, not decoration -
  /// found 2026-08-04, same day, breaking database opening on all three
  /// platforms.** Without it, going from `_gated(DbPickerScreen())` to
  /// `_gated(PinUnlockScreen())` across rebuilds produces two `Navigator`
  /// widgets of the same type at the same tree position with no key -
  /// Flutter's reconciliation treats that as "the same Navigator, just
  /// re-passed a new onGenerateRoute", reuses the existing NavigatorState,
  /// and does NOT re-invoke onGenerateRoute (that only happens once, to
  /// build the *initial* route - not on every rebuild of the Navigator
  /// widget itself). The screen visibly shown never advances past whatever
  /// was first displayed - confirmed via a debug-logged real run where
  /// DatabaseProvider/PinLockProvider's state correctly progressed all the
  /// way to `isReady=true, status=locked` (proving the open genuinely
  /// succeeded) while the UI stayed frozen on DbPickerScreen regardless,
  /// letting its still-live "Créer une nouvelle base" button fire against
  /// an already-open, already-schema'd database and throw "ACCOUNTLIST_V1
  /// already exists". Keying by the child's runtimeType makes the Navigator
  /// change identity - and therefore get properly torn down and rebuilt via
  /// a fresh onGenerateRoute call - exactly when the *conceptual* screen
  /// changes, while still preserving state across same-screen rebuilds
  /// (e.g. DbPickerScreen re-rendering through its own loading/error
  /// states) that don't actually need a reset.
  Widget _gated(Widget child) {
    return Navigator(
      key: ValueKey(child.runtimeType),
      onGenerateRoute: (_) => MaterialPageRoute(builder: (routeContext) {
        _maybeCheckForUpdates(routeContext);
        return child;
      }),
    );
  }
}
