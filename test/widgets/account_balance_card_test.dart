import 'package:flutter/gestures.dart' show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/models/account.dart';
import 'package:money_manager/widgets/account_balance_card.dart';

const _account = Account(
  id: 1,
  name: 'Compte courant',
  type: 'Checking',
  status: 'Open',
  initialBalance: 0,
  currencyId: 1,
  favorite: false,
);

Widget _host({VoidCallback? onTap, VoidCallback? onDoubleTap}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 210,
            height: 140,
            child: AccountBalanceCard(
              account: _account,
              balance: 100,
              onTap: onTap,
              onDoubleTap: onDoubleTap,
            ),
          ),
        ),
      ),
    );

/// The dashboard's double-tap-an-account-card-to-open-its-transactions
/// shortcut (DashboardScreen._openAccountTransactions) rests entirely on
/// this card telling a double-tap apart from a single tap - tested here on
/// the card alone, since the rest (HomeShell switching tabs) needs a real
/// open database to even reach.
void main() {
  testWidgets('a double-tap fires onDoubleTap, and neither of its two taps '
      'also fires onTap', (tester) async {
    var taps = 0;
    var doubleTaps = 0;
    await tester.pumpWidget(
        _host(onTap: () => taps++, onDoubleTap: () => doubleTaps++));

    final card = find.byType(AccountBalanceCard);
    await tester.tap(card);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(card);
    // Outlast the double-tap window, so a single-tap timer that wrongly
    // survived would have fired by now.
    await tester.pump(kDoubleTapTimeout);

    expect(doubleTaps, 1);
    expect(taps, 0);
  });

  testWidgets('a single tap still fires onTap once the double-tap window '
      'passes, and not onDoubleTap', (tester) async {
    var taps = 0;
    var doubleTaps = 0;
    await tester.pumpWidget(
        _host(onTap: () => taps++, onDoubleTap: () => doubleTaps++));

    await tester.tap(find.byType(AccountBalanceCard));
    await tester.pump(kDoubleTapTimeout);

    expect(taps, 1);
    expect(doubleTaps, 0);
  });

  testWidgets('without onDoubleTap, onTap fires immediately - no waiting '
      'for a second tap that can never matter', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(onTap: () => taps++));

    await tester.tap(find.byType(AccountBalanceCard));
    await tester.pump();

    expect(taps, 1);
  });
}
