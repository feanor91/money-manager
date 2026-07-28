import 'package:flutter/foundation.dart';

/// A "what-if" purchase simulation shared between the balance forecast
/// chart (dashboard) and the budget screen, so setting it once shows up
/// in both places instead of being local to whichever screen it was
/// entered from. Purely a client-side projection - never written to the
/// database.
class PurchaseSimulationProvider extends ChangeNotifier {
  double? amount;
  int installments = 1;
  int? categoryId;

  bool get isActive => amount != null;

  void set({required double amount, required int installments, int? categoryId}) {
    this.amount = amount;
    this.installments = installments;
    this.categoryId = categoryId;
    notifyListeners();
  }

  void clear() {
    amount = null;
    installments = 1;
    categoryId = null;
    notifyListeners();
  }
}
