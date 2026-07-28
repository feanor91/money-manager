import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:money_manager/app.dart';
import 'package:money_manager/state/database_provider.dart';
import 'package:money_manager/state/pin_lock_provider.dart';
import 'package:money_manager/state/purchase_simulation_provider.dart';

void main() {
  testWidgets('shows the database picker when no database is loaded', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => DatabaseProvider()),
          ChangeNotifierProvider(create: (_) => PinLockProvider()),
          ChangeNotifierProvider(create: (_) => PurchaseSimulationProvider()),
        ],
        child: const MoneyManagerApp(),
      ),
    );

    expect(find.text('Choisir un fichier .mmb'), findsOneWidget);
  });
}
