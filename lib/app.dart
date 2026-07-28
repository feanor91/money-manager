import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/db_picker_screen.dart';
import 'screens/home_shell.dart';
import 'screens/pin_lock_screen.dart';
import 'screens/settings_screen.dart';
import 'state/database_provider.dart';
import 'state/pin_lock_provider.dart';
import 'theme/app_theme.dart';

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
      routes: {
        '/settings': (_) => const SettingsScreen(),
      },
      home: const _RootGate(),
    );
  }
}

/// Shows the PIN screen while locked, the database picker until a database
/// is loaded, then the main app - in that order, so the PIN gate is checked
/// before anything about the database (or its content) is ever shown.
class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinLock = context.watch<PinLockProvider>();
    if (!pinLock.isUnlocked) {
      return const PinUnlockScreen();
    }
    final dbProvider = context.watch<DatabaseProvider>();
    if (dbProvider.isReady) {
      return const HomeShell();
    }
    return const DbPickerScreen();
  }
}
