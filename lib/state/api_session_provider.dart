import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
import 'package:money_manager_core/data/mmex_repository.dart' show RecurringOccurrence;
import 'package:money_manager_core/models/account.dart';
import 'package:money_manager_core/models/bill_deposit.dart';
import 'package:money_manager_core/models/budget.dart';
import 'package:money_manager_core/models/category.dart';
import 'package:money_manager_core/models/currency.dart';
import 'package:money_manager_core/models/payee.dart';
import 'package:money_manager_core/models/recurrence.dart';
import 'package:money_manager_core/models/sim_scenario.dart';
import 'package:money_manager_core/models/transaction.dart';

import '../services/api/api_client.dart';

/// Sentinelle "argument non fourni" pour [ApiSessionProvider.
/// upsertBudgetEnvelope] - même principe que [MmexRepository.
/// upsertBudgetEnvelope] côté serveur. Un `const Object()` est canonisé
/// par Dart (une seule instance pour toute expression `const Object()`
/// identique), donc cette sentinelle reste `identical()` à celle définie
/// séparément dans api_client.dart malgré les deux déclarations.
const _unset = Object();

/// État partagé de connexion au serveur API du chantier client/serveur
/// (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, étape 4) - une seule
/// instance pour toute l'appli, exactement comme [DatabaseProvider]/
/// [PinLockProvider]. L'URL du serveur est mémorisée en mémoire pour
/// cette session seulement (pas encore persistée entre deux lancements
/// de l'appli - limitation connue, à corriger si ce chantier avance).
/// Le jeton, lui, n'est jamais persisté du tout, par prudence (voir la
/// discussion sécurité du plan) - une reconnexion par code PIN est
/// nécessaire à chaque lancement de l'appli.
class ApiSessionProvider extends ChangeNotifier {
  final http.Client? _httpClient;
  ApiClient? _client;
  String? _error;
  bool _busy = false;

  /// Bascules de lecture par écran (étape 4) - un nom d'écran par entrée
  /// ('accounts', 'payees', 'categories', ...), en mémoire seulement pour
  /// l'instant (pas persistées entre deux lancements de l'appli). Vidées
  /// à la déconnexion pour ne jamais laisser un écran croire qu'il peut
  /// encore lire un serveur qui n'est plus joignable.
  final Set<String> _apiScreens = {};

  /// [httpClient] injectable pour les tests (voir
  /// test/state/api_session_provider_test.dart) - un vrai client HTTP par
  /// défaut sinon.
  ApiSessionProvider({http.Client? httpClient}) : _httpClient = httpClient;

  bool get isConnected => _client?.isLoggedIn ?? false;
  bool get isBusy => _busy;
  String? get error => _error;
  String? get serverUrl => _client?.baseUrl;

  /// Compteur incrémenté à chaque écriture réussie via l'API, depuis
  /// n'importe quel écran - chaque écran migré inclut sa valeur dans la clé
  /// qui décide de relancer [_loadViaApi] (voir dashboard_screen.dart et
  /// consorts). Comme [ApiSessionProvider] est déjà observé
  /// (`context.watch`) par tous ces écrans, y compris ceux cachés derrière
  /// l'IndexedStack de HomeShell (montés mais pas peints), l'incrémenter
  /// force TOUS les écrans à se relire au prochain changement, pas
  /// seulement celui où l'écriture a eu lieu - corrige le cas trouvé
  /// 2026-09-10 : enregistrer une occurrence d'opération récurrente
  /// laissait le grand livre affiché sur des données périmées tant qu'on
  /// ne changeait pas de compte pour forcer une relecture.
  int _dataVersion = 0;
  int get dataVersion => _dataVersion;
  void bumpDataVersion() {
    _dataVersion++;
    notifyListeners();
  }

  bool _useApiFor(String screen) => _apiScreens.contains(screen) && isConnected;
  void _setUseApiFor(String screen, bool value) {
    if (value) {
      _apiScreens.add(screen);
    } else {
      _apiScreens.remove(screen);
    }
    notifyListeners();
  }

  bool get useApiForAccounts => _useApiFor('accounts');
  set useApiForAccounts(bool value) => _setUseApiFor('accounts', value);

  bool get useApiForPayees => _useApiFor('payees');
  set useApiForPayees(bool value) => _setUseApiFor('payees', value);

  bool get useApiForCategories => _useApiFor('categories');
  set useApiForCategories(bool value) => _setUseApiFor('categories', value);

  bool get useApiForSpendingExplorer => _useApiFor('spendingExplorer');
  set useApiForSpendingExplorer(bool value) => _setUseApiFor('spendingExplorer', value);

  bool get useApiForRecurring => _useApiFor('recurring');
  set useApiForRecurring(bool value) => _setUseApiFor('recurring', value);

  bool get useApiForTransactions => _useApiFor('transactions');
  set useApiForTransactions(bool value) => _setUseApiFor('transactions', value);

  /// Vue "enveloppes" du Budget uniquement - le simulateur ("what if") du
  /// Budget lui-même reste entièrement local (scénarios/montants simulés,
  /// voir budget_screen.dart) ; l'écran Simulation séparé (long terme) a
  /// sa propre bascule ci-dessous.
  bool get useApiForBudget => _useApiFor('budget');
  set useApiForBudget(bool value) => _setUseApiFor('budget', value);

  /// Le tableau de bord lui-même, l'aperçu du budget et le graphique
  /// dépenses/catégorie - le graphique de prévision de solde
  /// (ForecastChart) reste toujours local, voir dashboard_screen.dart.
  bool get useApiForDashboard => _useApiFor('dashboard');
  set useApiForDashboard(bool value) => _setUseApiFor('dashboard', value);

  /// Écran Simulation (long terme, "what if") - voir simulation_screen.dart.
  bool get useApiForSimulation => _useApiFor('simulation');
  set useApiForSimulation(bool value) => _setUseApiFor('simulation', value);

  Future<void> login(String serverUrl, String pin) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final client = ApiClient(baseUrl: serverUrl, httpClient: _httpClient);
      await client.login(pin);
      _client = client;
    } catch (e) {
      _error = '$e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _client?.logout();
    _client = null;
    _apiScreens.clear();
    notifyListeners();
  }

  Future<List<Account>> getAccounts({bool onlyOpen = false}) => _requireClient().getAccounts(onlyOpen: onlyOpen);

  Future<CurrencyFormat?> getBaseCurrency() => _requireClient().getBaseCurrency();

  Future<double> accountBalance(int accountId, {DateTime? asOf}) =>
      _requireClient().accountBalance(accountId, asOf: asOf);

  Future<List<Payee>> getPayees({bool onlyActive = true}) =>
      _requireClient().getPayees(onlyActive: onlyActive);

  Future<int> payeeUsageCount(int payeeId) => _requireClient().payeeUsageCount(payeeId);

  Future<List<Category>> getCategories({bool onlyActive = true}) =>
      _requireClient().getCategories(onlyActive: onlyActive);

  Future<CategoryUsage> categoryUsage(int categoryId) => _requireClient().categoryUsage(categoryId);

  Future<List<MoneyTransaction>> getTransactionsFiltered({
    List<int>? years,
    List<int>? categoryIds,
    List<int>? payeeIds,
    List<int>? accountIds,
  }) =>
      _requireClient().getTransactionsFiltered(
        years: years,
        categoryIds: categoryIds,
        payeeIds: payeeIds,
        accountIds: accountIds,
      );

  Future<({int min, int max})?> transactionYearRangeAll() => _requireClient().transactionYearRangeAll();

  Future<List<BillDeposit>> getBillDeposits() => _requireClient().getBillDeposits();

  Future<Map<int, int>> billOccurrenceTotals() => _requireClient().billOccurrenceTotals();

  Future<({double percent, DateTime anchor})?> getBillAnnualIncrease(int billId) =>
      _requireClient().getBillAnnualIncrease(billId);

  Future<({double percent, DateTime anchor, double yearsSpan})?> suggestedAnnualIncrease(int billId) =>
      _requireClient().suggestedAnnualIncrease(billId);

  Future<List<TransactionWithBalance>> getTransactionsWithRunningBalance(int accountId,
          {DateTime? from, DateTime? to}) =>
      _requireClient().getTransactionsWithRunningBalance(accountId, from: from, to: to);

  Future<({int min, int max})?> transactionYearRange(int accountId) =>
      _requireClient().transactionYearRange(accountId);

  Future<Set<int>> recurringTransactionIds() => _requireClient().recurringTransactionIds();

  Future<Map<int, ({int index, int total})>> recurringTransactionOccurrences() =>
      _requireClient().recurringTransactionOccurrences();

  Future<List<BudgetEnvelope>> getBudgetEnvelopes(int accountId) =>
      _requireClient().getBudgetEnvelopes(accountId);

  Future<Map<int, double>> categoryMonthlyRecurringTotals({int? accountId}) =>
      _requireClient().categoryMonthlyRecurringTotals(accountId: accountId);

  Future<Map<int, double>> categorySpendForPeriod(
    DateTime start,
    DateTime end, {
    int? accountId,
    bool includeCategorizedTransfersAsExpense = false,
  }) =>
      _requireClient().categorySpendForPeriod(
        start,
        end,
        accountId: accountId,
        includeCategorizedTransfersAsExpense: includeCategorizedTransfersAsExpense,
      );

  Future<Map<int, DateTime>> lastSpendDatePerCategory(DateTime start, DateTime end,
          {int? accountId}) =>
      _requireClient().lastSpendDatePerCategory(start, end, accountId: accountId);

  Future<Set<int>> categoriesUsedByAccount(int accountId) =>
      _requireClient().categoriesUsedByAccount(accountId);

  Future<double> incomeForPeriod(DateTime start, DateTime end, {int? accountId}) =>
      _requireClient().incomeForPeriod(start, end, accountId: accountId);

  Future<double> expectedIncomeForBudget(int accountId) =>
      _requireClient().expectedIncomeForBudget(accountId);

  Future<List<MoneyTransaction>> getTransactions({
    int? accountId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) =>
      _requireClient().getTransactions(accountId: accountId, from: from, to: to, limit: limit);

  Future<double> forecastAccountBalance(int accountId, DateTime targetDate) =>
      _requireClient().forecastAccountBalance(accountId, targetDate);

  Future<DateTime?> forecastNegativeDate(int accountId, {int horizonDays = 365}) =>
      _requireClient().forecastNegativeDate(accountId, horizonDays: horizonDays);

  Future<Map<DateTime, double>> dailyNetTotals({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) =>
      _requireClient().dailyNetTotals(anchor: anchor, days: days, accountId: accountId);

  Future<Map<DateTime, double>> futureDailyNet({
    required DateTime after,
    required DateTime end,
    int? accountId,
  }) =>
      _requireClient().futureDailyNet(after: after, end: end, accountId: accountId);

  Future<Map<DateTime, double>> recurringDailyNet({
    required DateTime anchor,
    required int days,
    int? accountId,
  }) =>
      _requireClient().recurringDailyNet(anchor: anchor, days: days, accountId: accountId);

  Future<List<RecurringOccurrence>> recurringOccurrencesInRange({
    required DateTime start,
    required DateTime end,
    int? accountId,
  }) =>
      _requireClient().recurringOccurrencesInRange(start: start, end: end, accountId: accountId);

  // Écritures (chantier, non branchées en production - voir
  // PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, "Précision ajoutée le
  // 2026-09-10").

  // ---- Transactions ----
  Future<int> insertTransaction({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime date,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    bool reconciled = false,
  }) =>
      _requireClient().insertTransaction(
        accountId: accountId,
        payeeId: payeeId,
        transCode: transCode,
        amount: amount,
        date: date,
        categoryId: categoryId,
        toAccountId: toAccountId,
        toAmount: toAmount,
        notes: notes,
        reconciled: reconciled,
      );

  Future<void> updateTransaction(MoneyTransaction tx) => _requireClient().updateTransaction(tx);

  Future<void> deleteTransaction(int transId) => _requireClient().deleteTransaction(transId);

  Future<int> restoreTransaction(
    MoneyTransaction tx, {
    int? billId,
    int? occurrenceIndex,
    int? occurrenceTotal,
    bool? wasReconciledBeforePause,
  }) =>
      _requireClient().restoreTransaction(
        tx,
        billId: billId,
        occurrenceIndex: occurrenceIndex,
        occurrenceTotal: occurrenceTotal,
        wasReconciledBeforePause: wasReconciledBeforePause,
      );

  Future<void> setReconciled(int transId, bool reconciled) =>
      _requireClient().setReconciled(transId, reconciled);

  Future<int> resolveOrCreatePayee({required String name, int? categoryId}) =>
      _requireClient().resolveOrCreatePayee(name: name, categoryId: categoryId);

  Future<void> syncPausedTracking(int transId, {required bool paused, required bool reconciled}) =>
      _requireClient().syncPausedTracking(transId, paused: paused, reconciled: reconciled);

  Future<int?> billIdForTransaction(int transId) => _requireClient().billIdForTransaction(transId);

  Future<bool> wasReconciledBeforePause(int transId) =>
      _requireClient().wasReconciledBeforePause(transId);

  Future<int> countTransactionsMatching({required int payeeId, required int categoryId}) =>
      _requireClient().countTransactionsMatching(payeeId: payeeId, categoryId: categoryId);

  Future<void> bulkReassignTransactionCategory(
          {required int payeeId, required int oldCategoryId, required int newCategoryId}) =>
      _requireClient().bulkReassignTransactionCategory(
          payeeId: payeeId, oldCategoryId: oldCategoryId, newCategoryId: newCategoryId);

  Future<int> countTransfersMatching(
          {required int accountId, required int toAccountId, required int categoryId}) =>
      _requireClient().countTransfersMatching(
          accountId: accountId, toAccountId: toAccountId, categoryId: categoryId);

  Future<void> bulkReassignTransferCategory({
    required int accountId,
    required int toAccountId,
    required int oldCategoryId,
    required int newCategoryId,
  }) =>
      _requireClient().bulkReassignTransferCategory(
        accountId: accountId,
        toAccountId: toAccountId,
        oldCategoryId: oldCategoryId,
        newCategoryId: newCategoryId,
      );

  // ---- Comptes ----
  Future<int> insertAccount({
    required String name,
    required String type,
    required double initialBalance,
    required int currencyId,
  }) =>
      _requireClient().insertAccount(
          name: name, type: type, initialBalance: initialBalance, currencyId: currencyId);

  Future<void> updateAccount(Account account) => _requireClient().updateAccount(account);

  Future<void> deleteAccount(int accountId) => _requireClient().deleteAccount(accountId);

  // ---- Catégories ----
  Future<int> insertCategory({required String name, int? parentId}) =>
      _requireClient().insertCategory(name: name, parentId: parentId);

  Future<void> renameCategory(int categoryId, String newName) =>
      _requireClient().renameCategory(categoryId, newName);

  Future<void> setCategoryActive(int categoryId, bool active) =>
      _requireClient().setCategoryActive(categoryId, active);

  Future<void> deleteCategory(int categoryId) => _requireClient().deleteCategory(categoryId);

  Future<void> mergeCategories({required int fromId, required int toId}) =>
      _requireClient().mergeCategories(fromId: fromId, toId: toId);

  Future<void> moveCategory(int categoryId, int? newParentId) =>
      _requireClient().moveCategory(categoryId, newParentId);

  // ---- Tiers ----
  Future<void> renamePayee(int payeeId, String newName) =>
      _requireClient().renamePayee(payeeId, newName);

  Future<void> deletePayee(int payeeId) => _requireClient().deletePayee(payeeId);

  Future<void> mergePayees({required int fromId, required int toId}) =>
      _requireClient().mergePayees(fromId: fromId, toId: toId);

  // ---- Opérations récurrentes ----
  Future<int> insertBillDeposit({
    required int accountId,
    required int payeeId,
    required TransCode transCode,
    required double amount,
    required DateTime nextOccurrence,
    required RecurrencePeriod period,
    required RecurrenceAutoExecute autoExecute,
    int? categoryId,
    int? toAccountId,
    double? toAmount,
    String? notes,
    int numOccurrences = -1,
  }) =>
      _requireClient().insertBillDeposit(
        accountId: accountId,
        payeeId: payeeId,
        transCode: transCode,
        amount: amount,
        nextOccurrence: nextOccurrence,
        period: period,
        autoExecute: autoExecute,
        categoryId: categoryId,
        toAccountId: toAccountId,
        toAmount: toAmount,
        notes: notes,
        numOccurrences: numOccurrences,
      );

  Future<void> updateBillDeposit(BillDeposit bill) => _requireClient().updateBillDeposit(bill);

  Future<void> deleteBillDeposit(int bdId) => _requireClient().deleteBillDeposit(bdId);

  Future<void> setBillPaused(int billId, bool paused) =>
      _requireClient().setBillPaused(billId, paused);

  Future<void> setBillAnnualIncrease(int billId, {required double percent, required DateTime anchor}) =>
      _requireClient().setBillAnnualIncrease(billId, percent: percent, anchor: anchor);

  Future<void> clearBillAnnualIncrease(int billId) =>
      _requireClient().clearBillAnnualIncrease(billId);

  Future<void> ensureBillOccurrenceTotal(int billId, int total) =>
      _requireClient().ensureBillOccurrenceTotal(billId, total);

  Future<int> recordBillOccurrence(BillDeposit bill,
          {required DateTime date, bool reconciled = false, int splitInto = 1}) =>
      _requireClient()
          .recordBillOccurrence(bill, date: date, reconciled: reconciled, splitInto: splitInto);

  Future<List<int>> catchUpBillDeposit(BillDeposit bill, DateTime asOf, {bool reconciled = false}) =>
      _requireClient().catchUpBillDeposit(bill, asOf, reconciled: reconciled);

  // ---- Budget (vue enveloppes uniquement - le simulateur reste local) ----
  Future<void> upsertBudgetEnvelope({
    int? id,
    required int accountId,
    required int categoryId,
    required double amount,
    Object? name = _unset,
    Object? manualOverride = _unset,
  }) =>
      _requireClient().upsertBudgetEnvelope(
        id: id,
        accountId: accountId,
        categoryId: categoryId,
        amount: amount,
        name: name,
        manualOverride: manualOverride,
      );

  Future<void> deleteBudgetEnvelope(int id) => _requireClient().deleteBudgetEnvelope(id);

  Future<void> setIncomeTargetOverride(int accountId, double amount) =>
      _requireClient().setIncomeTargetOverride(accountId, amount);

  Future<double?> getIncomeTargetOverride(int accountId) =>
      _requireClient().getIncomeTargetOverride(accountId);

  Future<void> clearIncomeTargetOverride(int accountId) =>
      _requireClient().clearIncomeTargetOverride(accountId);

  Future<double> monthlyRecurringIncome({int? accountId}) =>
      _requireClient().monthlyRecurringIncome(accountId: accountId);

  Future<Map<int, double>> incomeCategoryTotalsForPeriod(DateTime start, DateTime end,
          {int? accountId}) =>
      _requireClient().incomeCategoryTotalsForPeriod(start, end, accountId: accountId);

  Future<void> resetBudgetEnvelopes(int accountId) =>
      _requireClient().resetBudgetEnvelopes(accountId);

  // ---- Simulation ("what if" scenarios de long terme) ----

  Future<List<SimScenario>> getSimScenarios() => _requireClient().getSimScenarios();

  Future<int> createSimScenario(String name) => _requireClient().createSimScenario(name);

  Future<void> renameSimScenario(int scenarioId, String name) =>
      _requireClient().renameSimScenario(scenarioId, name);

  Future<int> duplicateSimScenario(int sourceScenarioId, String newName) =>
      _requireClient().duplicateSimScenario(sourceScenarioId, newName);

  Future<void> deleteSimScenario(int scenarioId) =>
      _requireClient().deleteSimScenario(scenarioId);

  Future<List<SimBillOverride>> getSimBillOverrides(int scenarioId) =>
      _requireClient().getSimBillOverrides(scenarioId);

  Future<void> upsertSimBillOverride(int scenarioId, int billId,
          {DateTime? disabledFrom, double? amountOverride}) =>
      _requireClient().upsertSimBillOverride(scenarioId, billId,
          disabledFrom: disabledFrom, amountOverride: amountOverride);

  Future<void> deleteSimBillOverride(int scenarioId, int billId) =>
      _requireClient().deleteSimBillOverride(scenarioId, billId);

  Future<List<SimVirtualBill>> getSimVirtualBills(int scenarioId) =>
      _requireClient().getSimVirtualBills(scenarioId);

  Future<int> addSimVirtualBill({
    required int scenarioId,
    required int accountId,
    required String label,
    required TransCode transCode,
    required double amount,
    required DateTime startDate,
    required RecurrencePeriod period,
    int numOccurrences = -1,
    double variancePercent = 0,
    double annualIncreasePercent = 0,
    DateTime? annualIncreaseAnchor,
  }) =>
      _requireClient().addSimVirtualBill(
        scenarioId: scenarioId,
        accountId: accountId,
        label: label,
        transCode: transCode,
        amount: amount,
        startDate: startDate,
        period: period,
        numOccurrences: numOccurrences,
        variancePercent: variancePercent,
        annualIncreasePercent: annualIncreasePercent,
        annualIncreaseAnchor: annualIncreaseAnchor,
      );

  Future<void> deleteSimVirtualBill(int virtualBillId) =>
      _requireClient().deleteSimVirtualBill(virtualBillId);

  Future<List<SimOneOffEvent>> getSimOneOffEvents(int scenarioId) =>
      _requireClient().getSimOneOffEvents(scenarioId);

  Future<int> addSimOneOffEvent({
    required int scenarioId,
    required int accountId,
    required String label,
    required TransCode transCode,
    required double amount,
    required DateTime date,
  }) =>
      _requireClient().addSimOneOffEvent(
        scenarioId: scenarioId,
        accountId: accountId,
        label: label,
        transCode: transCode,
        amount: amount,
        date: date,
      );

  Future<void> deleteSimOneOffEvent(int eventId) =>
      _requireClient().deleteSimOneOffEvent(eventId);

  Future<({bool enabled, double? equilibrium, double strength, double noisePercent})?>
      getSimMeanReversion(int scenarioId, int accountId) =>
          _requireClient().getSimMeanReversion(scenarioId, accountId);

  Future<void> setSimMeanReversion(
    int scenarioId,
    int accountId, {
    required bool enabled,
    double? equilibrium,
    required double strength,
    required double noisePercent,
  }) =>
      _requireClient().setSimMeanReversion(scenarioId, accountId,
          enabled: enabled, equilibrium: equilibrium, strength: strength, noisePercent: noisePercent);

  Future<void> setSimMeanReversionEnabled(int scenarioId, int accountId, bool enabled) =>
      _requireClient().setSimMeanReversionEnabled(scenarioId, accountId, enabled);

  Future<void> deleteSimMeanReversion(int scenarioId, int accountId) =>
      _requireClient().deleteSimMeanReversion(scenarioId, accountId);

  Future<List<DateTime>> occurrencesForBill(BillDeposit bill, DateTime start, DateTime end) =>
      _requireClient().occurrencesForBill(bill, start, end);

  Future<double> historicalDiscretionaryMonthlyAverage(
          {int? accountId, required DateTime anchor, required int startDay, int months = 12}) =>
      _requireClient().historicalDiscretionaryMonthlyAverage(
          accountId: accountId, anchor: anchor, startDay: startDay, months: months);

  Future<double> historicalDiscretionaryMonthlyStdev(
          {int? accountId, required DateTime anchor, required int startDay, int months = 12}) =>
      _requireClient().historicalDiscretionaryMonthlyStdev(
          accountId: accountId, anchor: anchor, startDay: startDay, months: months);

  Future<double> historicalEquilibriumBalance(
          {required int accountId, required DateTime anchor, required int startDay, int months = 12}) =>
      _requireClient().historicalEquilibriumBalance(
          accountId: accountId, anchor: anchor, startDay: startDay, months: months);

  Future<SimulationChartResult> computeSimulationChart({
    required int scenarioId,
    required int accountId,
    required DateTime anchor,
    required int days,
    required int startDay,
  }) =>
      _requireClient().computeSimulationChart(
        scenarioId: scenarioId,
        accountId: accountId,
        anchor: anchor,
        days: days,
        startDay: startDay,
      );

  ApiClient _requireClient() {
    final client = _client;
    if (client == null) throw StateError('Pas connecté au serveur API.');
    return client;
  }
}
