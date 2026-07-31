import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:money_manager/app.dart';
import 'package:money_manager/state/database_provider.dart';
import 'package:money_manager/state/pin_lock_provider.dart';
import 'package:money_manager/state/purchase_simulation_provider.dart';

void main() {
  testWidgets('shows the database picker when no database is loaded', (tester) async {
    final pinLockProvider = PinLockProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => DatabaseProvider(
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
            ),
          ),
          ChangeNotifierProvider.value(value: pinLockProvider),
          ChangeNotifierProvider(create: (_) => PurchaseSimulationProvider()),
        ],
        child: const MoneyManagerApp(),
      ),
    );

    expect(find.text('Choisir un fichier .mmb'), findsOneWidget);
  });
}
