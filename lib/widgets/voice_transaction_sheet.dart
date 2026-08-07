import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/account.dart';
import '../models/category.dart';
import '../models/payee.dart';
import '../models/transaction.dart' show TransCode;
import '../services/voice_entry/voice_transaction_parser.dart';
import '../utils/list_utils.dart' show findById;

/// Captures one spoken sentence and turns it into a [VoiceTransactionDraft]
/// via [parseVoiceTransaction] - Android only (see transactions_screen.dart's
/// `_isAndroidPlatform` gate on the "Par la voix" entry point; this widget
/// itself doesn't re-check the platform, since speech_to_text's web/desktop
/// backends are simply never exercised if nothing ever opens this sheet
/// there).
///
/// Deliberately does *not* support transfers: recognizing a second (target)
/// account from speech would need its own name-matching pass with its own
/// false-positive risk, for a transaction type voice entry is unlikely to
/// be used for in the first place (a transfer between the user's own
/// accounts is usually planned, not dashed off by voice) - out of scope for
/// now, not forgotten.
class VoiceTransactionSheet extends StatefulWidget {
  final List<Payee> payees;
  final List<Category> categories;
  final List<Account> accounts;

  const VoiceTransactionSheet({
    super.key,
    required this.payees,
    required this.categories,
    required this.accounts,
  });

  @override
  State<VoiceTransactionSheet> createState() => _VoiceTransactionSheetState();
}

class _VoiceTransactionSheetState extends State<VoiceTransactionSheet> {
  final _speech = stt.SpeechToText();
  bool _initializing = true;
  bool _available = false;
  bool _listening = false;
  String _transcript = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    // Belt-and-braces: if the sheet is dismissed (back gesture, tap outside)
    // while still listening, don't leave the recognizer running past the
    // widget that owns its callbacks.
    if (_listening) _speech.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final available = await _speech.initialize(
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          _error = 'Erreur de reconnaissance vocale (${error.errorMsg}).';
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => _listening = false);
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _available = available;
      _initializing = false;
    });
    if (available) _startListening();
  }

  void _startListening() {
    setState(() {
      _listening = true;
      _error = null;
      _transcript = '';
    });
    _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _transcript = result.recognizedWords);
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: 'fr_FR',
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 30),
      ),
    );
  }

  void _confirm() {
    _speech.stop();
    final draft = parseVoiceTransaction(
      _transcript,
      payees: widget.payees,
      categories: widget.categories,
      accounts: widget.accounts,
    );
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Live preview of what parseVoiceTransaction actually understood -
    // added 2026-08-07 after a report that the recognized account never
    // made it into the transaction, to show right here whether the miss is
    // in parsing itself or somewhere after (TransactionEditorSheet's own
    // prefill) - and useful in its own right either way, catching a
    // misheard payee/compte before opening the full form instead of after.
    final draft = _transcript.isEmpty
        ? null
        : parseVoiceTransaction(_transcript,
            payees: widget.payees, categories: widget.categories, accounts: widget.accounts);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Saisie vocale', style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          if (_initializing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            )
          else if (!_available)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Reconnaissance vocale indisponible sur cet appareil, ou '
                'accès au micro refusé.',
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            InkWell(
              onTap: _listening ? _speech.stop : _startListening,
              borderRadius: BorderRadius.circular(48),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _listening
                      ? theme.colorScheme.errorContainer
                      : theme.colorScheme.primaryContainer,
                ),
                child: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  size: 40,
                  color: _listening
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(_listening ? 'À l\'écoute…' : 'Appuyez pour parler à nouveau'),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _transcript.isEmpty ? 'Ex. : "35 euros chez Carrefour hier"' : _transcript,
                style: _transcript.isEmpty
                    ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                    : null,
              ),
            ),
            if (draft != null) ...[
              const SizedBox(height: 8),
              _ParsedPreview(
                draft: draft,
                payees: widget.payees,
                categories: widget.categories,
                accounts: widget.accounts,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Annuler'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _transcript.isEmpty ? null : _confirm,
                child: const Text('Continuer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the transcript's *interpretation*, not just its raw text - lets a
/// misheard payee/compte be caught right here instead of only surfacing
/// once the full form is already open (or not surfacing at all, which is
/// what a silent parsing miss looked like before this existed).
class _ParsedPreview extends StatelessWidget {
  final VoiceTransactionDraft draft;
  final List<Payee> payees;
  final List<Category> categories;
  final List<Account> accounts;

  const _ParsedPreview({
    required this.draft,
    required this.payees,
    required this.categories,
    required this.accounts,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payeeName = findById(payees, draft.payeeId, (p) => p.id)?.name;
    final categoryName = findById(categories, draft.categoryId, (c) => c.id)?.name;
    final accountName = findById(accounts, draft.accountId, (a) => a.id)?.name;

    final mainParts = <String>[
      if (draft.amount != null)
        '${draft.transCode == TransCode.deposit ? '+' : '-'}${draft.amount!.toStringAsFixed(2)} €',
      if (payeeName != null) 'chez $payeeName',
      if (categoryName != null) '($categoryName)',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mainParts.isNotEmpty)
          Text(
            'Compris : ${mainParts.join(' ')}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        Text(
          accountName != null ? 'Compte reconnu : $accountName' : 'Compte : inchangé',
          style: theme.textTheme.bodySmall?.copyWith(
            color: accountName != null
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: accountName != null ? FontWeight.w600 : null,
          ),
        ),
      ],
    );
  }
}
