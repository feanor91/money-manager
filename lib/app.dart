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

  /// Created once, for _PinGate's whole lifetime (the entire app session) -
  /// unlike the old per-screen keys this replaced, this Navigator is never
  /// torn down or recreated as the gate progresses through db-picker → PIN
  /// → unlocked. See [_gated]'s doc comment for why that stability is the
  /// whole point.
  final _gateNavigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Starts the update check the moment [_gated]'s Navigator first has a
  /// usable context - which happens exactly once, on the very first build,
  /// since (unlike the old design) this Navigator's identity never changes
  /// for the rest of the session, so its route builder only ever runs once
  /// too. Guarded regardless, in case that assumption ever stops holding.
  ///
  /// **Found 2026-08-07, the same day this shipped**: the previous design
  /// re-created a *new* Navigator (and therefore a new dialog host) every
  /// time the visible gate screen changed (db-picker → PIN, or PIN →
  /// unlocked) - a `showDialog` opened on one of those Navigators got torn
  /// down the instant the gate advanced to the next screen, which on
  /// Android (where the database often restores automatically, advancing
  /// straight past the picker) could happen within the same second the
  /// update dialog first appeared: it flashed on screen and vanished before
  /// the user could read it, let alone tap anything. Routing the dialog
  /// through this one stable Navigator instead means it now survives every
  /// later gate transition intact - a modal dialog blocks interaction with
  /// whatever's behind it, so this also satisfies the follow-up request
  /// ("stop the workflow" while the prompt is up): the PIN screen can be
  /// mounted behind it, but isn't reachable until the dialog is dismissed.
  void _maybeCheckForUpdates(BuildContext context) {
    if (_updateCheckStarted) return;
    _updateCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) checkForUpdatesAndPrompt(context);
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
  Widget build(BuildContext context) => _gated(_GateContent(child: widget.child));

  /// Wraps the whole gate (db-picker → PIN → [widget.child] once unlocked)
  /// in one single-route Navigator that lives for _PinGate's entire
  /// lifetime - i.e. the whole app session - so it has an Overlay ancestor
  /// of its own no matter which gate screen is conceptually "on top".
  ///
  /// Found 2026-08-04 diagnosing a PIN entry bug (desktop backspace-then-
  /// retype could resurrect deleted digits): without this, these screens sit
  /// directly in MaterialApp.builder's slot, entirely outside any real
  /// Navigator/Overlay. The instant PinUnlockScreen's autofocused field
  /// actually gained focus, EditableText's focus-changed handler tried to
  /// show selection handles via Overlay.of(context) and hit a null-check
  /// crash (no Overlay ancestor exists) - confirmed via a debug-logged real
  /// run: initState → one build() → the crash's stack trace (Overlay.of →
  /// SelectionOverlay.showHandles → TextSelectionOverlay.showHandles →
  /// EditableTextState._handleSelectionChanged/_handleFocusChanged) → then
  /// dozens of build() calls in ~200ms as the framework tried to recover.
  /// That crash happening mid-way through EditableText's own focus/
  /// selection bookkeeping is what left it in a state where later
  /// backspace/retype edits could desync - not a bug in the PIN field's own
  /// code at all. DbPickerScreen/PinCompanionAccessScreen never surfaced
  /// this only because neither happens to autofocus a text field - they
  /// were silently exposed to the exact same missing-Overlay condition the
  /// whole time.
  ///
  /// **A single stable Navigator, not one recreated per screen - found
  /// 2026-08-07, replacing an earlier `key: ValueKey(child.runtimeType)`
  /// design that intentionally tore down and rebuilt this Navigator every
  /// time the conceptual screen changed.** That design fixed a real bug of
  /// its own the same day it was introduced (see below), but caused a new
  /// one the moment update_prompt.dart started opening a dialog from here:
  /// a `showDialog` call attaches to *this* Navigator, so tearing it down
  /// on the very next gate transition (db-picker → PIN, which on Android
  /// can happen within the same second when the database restores
  /// automatically) destroyed the dialog with it - the update prompt
  /// flashed on screen and vanished before it could be read. [_GateContent]
  /// solves the *original* problem differently: instead of forcing a new
  /// Navigator/route to make the visible screen advance, it just watches
  /// [DatabaseProvider]/[PinLockProvider] directly and picks the right
  /// widget on every ordinary rebuild - which needs no route replacement at
  /// all, so this Navigator can now stay the same for the whole session. A
  /// `showDialog` opened on it (see update_prompt.dart) now survives every
  /// later gate transition intact, and - being modal - blocks interaction
  /// with whatever's mounted behind it until dismissed.
  Widget _gated(Widget child) {
    return Navigator(
      key: _gateNavigatorKey,
      onGenerateRoute: (_) => MaterialPageRoute(builder: (routeContext) {
        _maybeCheckForUpdates(routeContext);
        return child;
      }),
    );
  }
}

/// Picks which gate screen (or the real app) to show, purely by watching
/// [DatabaseProvider]/[PinLockProvider] - deliberately NOT dependent on
/// [Navigator] route replacement to update (see [_PinGateState._gated]'s
/// doc comment for why). Mounted once as the single, permanent content of
/// _PinGate's one stable Navigator; Flutter's ordinary conditional-widget
/// reconciliation (different runtime type ⇒ old subtree unmounted, new one
/// mounted fresh) still resets each screen's own internal state exactly
/// the same way switching between different widgets in any build method
/// always has - no Navigator/key trick needed for that part.
class _GateContent extends StatelessWidget {
  final Widget? child;

  const _GateContent({required this.child});

  @override
  Widget build(BuildContext context) {
    // Database first: the PIN (and every other preference) now lives in
    // that database's own companion settings file, so there is nothing to
    // check the PIN gate against until a database is open - see
    // PinLockProvider.attachDatabase and CLAUDE.md.
    final dbProvider = context.watch<DatabaseProvider>();
    if (!dbProvider.isReady) {
      return const DbPickerScreen();
    }
    final pinLock = context.watch<PinLockProvider>();
    switch (pinLock.status) {
      case PinGateStatus.needsCompanionAccess:
        return const PinCompanionAccessScreen();
      case PinGateStatus.locked:
        return const PinUnlockScreen();
      case PinGateStatus.none:
      case PinGateStatus.unlocked:
        return child!;
    }
  }
}
