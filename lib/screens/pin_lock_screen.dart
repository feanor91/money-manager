import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/database_provider.dart';
import '../state/pin_lock_provider.dart';
import '../theme/app_theme.dart';

/// Masks a PIN field as bullets while tracking the real digits via
/// [setValue]/[getValue], WITHOUT ever using `obscureText: true`. That
/// matters specifically on web: `obscureText: true` renders as a genuine
/// `<input type="password">` under the hood, and browsers/password
/// managers target that for autofill/autosuggest *regardless* of
/// `autofillHints`/`autocomplete` - browsers have widely ignored
/// `autocomplete="off"` on password fields for a decade now, precisely
/// because sites used to abuse it to block legitimate password-manager use.
/// A masked-but-`type="text"` field labelled "Code PIN" isn't recognized as
/// a login field by any reasonable autofill heuristic, so this sidesteps
/// the problem entirely instead of asking browsers nicely not to interfere.
/// Only supports appending/deleting from the end (standard for PIN entry -
/// no mid-string cursor editing), which keeps the masking logic simple: the
/// masked text's length always equals the real value's length, so the
/// diff between old/new masked lengths tells us exactly how many real
/// characters were typed or removed.
TextInputFormatter pinMaskFormatter({
  required String Function() getValue,
  required void Function(String) setValue,
}) {
  return TextInputFormatter.withFunction((oldValue, newValue) {
    final real = getValue();
    final delta = newValue.text.length - oldValue.text.length;
    final updated = delta > 0
        ? real + newValue.text.substring(newValue.text.length - delta)
        : delta < 0
            ? real.substring(0, (real.length + delta).clamp(0, real.length))
            : real;
    setValue(updated);
    final masked = '•' * updated.length;
    return TextEditingValue(
      text: masked,
      selection: TextSelection.collapsed(offset: masked.length),
    );
  });
}

/// Web only: shown instead of [PinUnlockScreen] when a database is open but
/// this browser doesn't (yet, or any more) have permission to the folder
/// its companion settings file lives in - see
/// DatabaseProvider.retryCompanionAccess and PinGateStatus.needsCompanionAccess.
/// Whether a PIN is even configured is unknown until that permission is
/// granted, so this blocks entry rather than guessing either way.
class PinCompanionAccessScreen extends StatefulWidget {
  const PinCompanionAccessScreen({super.key});

  @override
  State<PinCompanionAccessScreen> createState() =>
      _PinCompanionAccessScreenState();
}

class _PinCompanionAccessScreenState extends State<PinCompanionAccessScreen> {
  bool _requesting = false;
  String? _error;

  Future<void> _retry() async {
    setState(() {
      _requesting = true;
      _error = null;
    });
    await context.read<DatabaseProvider>().retryCompanionAccess();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      // If access was actually granted, DatabaseProvider's own state change
      // has already moved _RootGate off this screen by the time we get
      // here - reaching this line at all means the user declined again.
      _error = 'Accès toujours refusé - réessayez, ou choisissez un autre fichier.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_shared_outlined,
                    size: 48, color: AppTheme.accent),
                const SizedBox(height: 16),
                Text('Accès au dossier requis',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                const Text(
                  'Le navigateur requiert l\'accès au dossier de stockage de '
                  'la base de données, merci de bien vouloir l\'autoriser.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _requesting ? null : _retry,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Autoriser l\'accès au dossier'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: AppTheme.negative),
                      textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen PIN prompt shown whenever the app is locked - see
/// [PinLockProvider]. Not a route the user can navigate away from short of
/// entering the right code.
class PinUnlockScreen extends StatefulWidget {
  const PinUnlockScreen({super.key});

  @override
  State<PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends State<PinUnlockScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _pin = '';
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  Future<void> _submit() async {
    final pin = _pin;
    if (pin.isEmpty) return;
    setState(() => _checking = true);
    final result = await context.read<PinLockProvider>().verify(pin);
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (!result.ok) {
        _controller.clear();
        _pin = '';
        final lockout = result.lockoutRemaining;
        if (lockout != null) {
          _error = 'Trop de tentatives. Réessayez dans ${_formatLockout(lockout)}.';
        } else if (result.attemptsRemaining == 1) {
          _error = 'Code incorrect (dernier essai avant blocage temporaire)';
        } else {
          _error = 'Code incorrect (${result.attemptsRemaining} essais restants)';
        }
      }
    });
  }

  String _formatLockout(Duration d) {
    final seconds = d.inMilliseconds / 1000;
    final rounded = seconds.ceil();
    if (rounded <= 60) return '$rounded s';
    return '${(rounded / 60).ceil()} min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 48, color: AppTheme.accent),
                const SizedBox(height: 16),
                Text('Money Manager verrouillé',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  obscureText: false,
                  inputFormatters: [
                    pinMaskFormatter(
                      getValue: () => _pin,
                      setValue: (v) => _pin = v,
                    ),
                  ],
                  autofillHints: const [],
                  enableSuggestions: false,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, letterSpacing: 8),
                  decoration: InputDecoration(
                    labelText: 'Code PIN',
                    errorText: _error,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _checking ? null : _submit,
                  child: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Déverrouiller'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lets the user choose (or change) their PIN, from Settings. Requires
/// entering it twice to catch typos, since there's no recovery mechanism -
/// forgetting it means removing and re-setting from within the app itself
/// while still unlocked.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  String _pin = '';
  String _confirm = '';
  late final _maxAttemptsController = TextEditingController(
      text: '${context.read<PinLockProvider>().maxAttempts}');
  late final _lockoutMinutesController = TextEditingController(
      text: '${context.read<PinLockProvider>().lockoutMinutes}');
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    _maxAttemptsController.dispose();
    _lockoutMinutesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pin = _pin;
    final confirm = _confirm;
    if (pin.length < 4) {
      setState(() => _error = 'Au moins 4 chiffres');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'Les deux codes ne correspondent pas');
      return;
    }
    final maxAttempts = int.tryParse(_maxAttemptsController.text.trim());
    if (maxAttempts == null ||
        maxAttempts < PinLockProvider.minAttempts ||
        maxAttempts > PinLockProvider.maxAttemptsAllowed) {
      setState(() => _error =
          'Tentatives avant blocage : entre ${PinLockProvider.minAttempts} et ${PinLockProvider.maxAttemptsAllowed}');
      return;
    }
    final lockoutMinutes = int.tryParse(_lockoutMinutesController.text.trim());
    if (lockoutMinutes == null ||
        lockoutMinutes < PinLockProvider.minLockoutMinutes ||
        lockoutMinutes > PinLockProvider.maxLockoutMinutes) {
      setState(() => _error =
          'Durée du blocage : entre ${PinLockProvider.minLockoutMinutes} et ${PinLockProvider.maxLockoutMinutes} minutes');
      return;
    }

    final provider = context.read<PinLockProvider>();
    await provider.setPin(pin);
    await provider.setMaxAttempts(maxAttempts);
    await provider.setLockoutMinutes(lockoutMinutes);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Définir un code PIN')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _pinController,
              autofocus: true,
              obscureText: false,
              inputFormatters: [
                pinMaskFormatter(
                  getValue: () => _pin,
                  setValue: (v) => _pin = v,
                ),
              ],
              autofillHints: const [],
              enableSuggestions: false,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Nouveau code PIN'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmController,
              obscureText: false,
              inputFormatters: [
                pinMaskFormatter(
                  getValue: () => _confirm,
                  setValue: (v) => _confirm = v,
                ),
              ],
              autofillHints: const [],
              enableSuggestions: false,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Confirmer le code'),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxAttemptsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Tentatives avant blocage'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lockoutMinutesController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Durée du blocage (min)'),
                    onSubmitted: (_) => _save(),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppTheme.negative)),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
  }
}
