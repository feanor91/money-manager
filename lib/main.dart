import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'state/database_provider.dart';
import 'state/pin_lock_provider.dart';
import 'state/purchase_simulation_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');

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
