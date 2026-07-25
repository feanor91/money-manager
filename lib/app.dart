import 'package:flutter/material.dart';
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
    return MaterialApp(
      title: 'Money Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
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
    // Re-lock as soon as the app leaves the foreground (mobile: home
    // button, app switcher, incoming call) - a PIN only checked once at
    // launch wouldn't do much for a phone left unlocked on a table.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
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
