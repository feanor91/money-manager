import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/nl_query/local_llm/local_llm_manager.dart';
import 'state/database_provider.dart';
import 'state/pin_lock_provider.dart';
import 'state/purchase_simulation_provider.dart';
import 'state/unsaved_changes_guard.dart';

/// Kills a still-running local-AI `llama-server.exe` (Windows desktop only
/// - a no-op everywhere else, see local_llm_manager.dart) once the engine
/// reports it's tearing down, so the process never outlives the app itself
/// and sits there holding a multi-gigabyte model in RAM indefinitely.
/// `detached` is the state Flutter reports for a normally-closed desktop
/// window; see local_llm_manager_io.dart's `registerLocalLlmSignalShutdownHook`
/// for the console/Ctrl+C case this doesn't cover.
class _LocalLlmShutdownObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(shutdownLocalLlmEngine());
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  WidgetsBinding.instance.addObserver(_LocalLlmShutdownObserver());
  registerLocalLlmSignalShutdownHook();

  final pinLockProvider = PinLockProvider();
  final dbProvider = DatabaseProvider(
    onDatabaseContextChanged: ({
      required databaseReady,
      required companionPrefs,
      companionUnreachable = false,
    }) =>
        pinLockProvider.attachDatabase(
      databaseReady: databaseReady,
      companionPrefs: companionPrefs,
      companionUnreachable: companionUnreachable,
    ),
  );
  unawaited(dbProvider.restoreLastDatabase());
  registerUnsavedChangesGuard(() => dbProvider.hasPendingWrite);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: dbProvider),
        ChangeNotifierProvider.value(value: pinLockProvider),
        ChangeNotifierProvider(create: (_) => PurchaseSimulationProvider()),
      ],
      child: const MoneyManagerApp(),
    ),
  );
}
