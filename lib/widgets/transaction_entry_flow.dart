import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../screens/transactions_screen.dart' show TransactionEditorResult, TransactionEditorSheet;
import '../services/voice_entry/voice_transaction_parser.dart';
import '../state/database_provider.dart';
import 'bill_amount_sync.dart';
import 'bulk_category_reassign.dart';
import 'voice_transaction_sheet.dart';

/// Opens [TransactionEditorSheet] and handles everything it can pop back -
/// `touch()` to persist, then any deferred-to-after-close follow-up (bulk
/// category reassign, bill-amount sync). Shared by the ledger's own "+" and
/// the dashboard's, so both stay in lockstep instead of silently drifting
/// apart the way they already did once: the dashboard used to keep its own
/// separate copy of this, which fell out of sync with a return-type change
/// here and silently stopped persisting anything saved through it (found
/// 2026-08-06) - see ROADMAP.md. Consolidated here after the same class of
/// drift risk came up again for [startVoiceEntry] below (2026-08-07).
Future<void> openTransactionEditor(
  BuildContext context, {
  MoneyTransaction? existing,
  int? defaultAccountId,
  VoiceTransactionDraft? voicePrefill,
  MoneyTransaction? duplicateFrom,
}) async {
  final dbProvider = context.read<DatabaseProvider>();
  final repo = dbProvider.repository!;
  final result = await showModalBottomSheet<TransactionEditorResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TransactionEditorSheet(
      existing: existing,
      repo: repo,
      defaultAccountId: defaultAccountId,
      voicePrefill: voicePrefill,
      duplicateFrom: duplicateFrom,
    ),
  );
  dbProvider.touch();
  if (result?.categoryChange != null && context.mounted) {
    await offerBulkCategoryReassign(
      context: context,
      repo: repo,
      dbProvider: dbProvider,
      change: result!.categoryChange!,
    );
  }
  if (result?.billAmountChange != null && context.mounted) {
    await offerBillAmountSync(
      context: context,
      repo: repo,
      dbProvider: dbProvider,
      change: result!.billAmountChange!,
    );
  }
  // "Dupliquer" was tapped - reopen a fresh "Nouvelle transaction" sheet
  // seeded from the source transaction, only once this one has fully
  // closed (same deferred-to-after-close convention as the two follow-ups
  // above).
  if (result?.duplicateFrom != null && context.mounted) {
    await openTransactionEditor(
      context,
      defaultAccountId: defaultAccountId,
      duplicateFrom: result!.duplicateFrom,
    );
  }
}

/// Opens the mic-capture sheet, then - if the user went through with it -
/// the same "Nouvelle transaction" sheet as manual entry, pre-filled with
/// whatever [parseVoiceTransaction] made of the transcript. Nothing is ever
/// saved directly from speech: the user always confirms in that sheet.
Future<void> startVoiceEntry(BuildContext context, int? accountId) async {
  final dbProvider = context.read<DatabaseProvider>();
  final repo = dbProvider.repository!;
  final draft = await showModalBottomSheet<VoiceTransactionDraft>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VoiceTransactionSheet(
      payees: repo.getPayees(onlyActive: false),
      categories: repo.getCategories(),
      // Masked accounts excluded - found 2026-08-07: a hidden account
      // sharing a word with an active one ("Boursorama Perso Livret",
      // masked, vs "Boursorama Perso") tied the word-overlap match and
      // silently gave up rather than guess, even though only the active
      // account was ever a real candidate.
      accounts: repo.getAccounts().where((a) => !dbProvider.isAccountHidden(a.id)).toList(),
    ),
  );
  if (!context.mounted || draft == null) return;
  await openTransactionEditor(context, defaultAccountId: accountId, voicePrefill: draft);
}
