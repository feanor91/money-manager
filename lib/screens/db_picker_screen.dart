import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/database_provider.dart';
import '../theme/app_theme.dart';

/// Shown at startup when no database is loaded yet (or on error), and
/// reachable again from Settings to switch to a different .mmb file.
class DbPickerScreen extends StatelessWidget {
  const DbPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(Icons.account_balance_wallet_outlined,
                        size: 40, color: AppTheme.accent),
                  ),
                  const SizedBox(height: 24),
                  Text('Money Manager', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    dbProvider.status == DbStatus.needsReconnect
                        ? 'Le navigateur a besoin de confirmer l\'accès à votre fichier'
                            '${dbProvider.reconnectFileName != null ? ' "${dbProvider.reconnectFileName}"' : ''}.'
                        : 'Choisissez l\'emplacement de votre base MoneyManager Ex (.mmb) pour commencer.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 32),
                  if (dbProvider.status == DbStatus.loading)
                    const CircularProgressIndicator()
                  else if (dbProvider.status == DbStatus.needsReconnect) ...[
                    FilledButton.icon(
                      onPressed: () => context.read<DatabaseProvider>().reconnectWebFile(),
                      icon: const Icon(Icons.link),
                      label: const Text('Reconnecter'),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => context.read<DatabaseProvider>().pickDatabaseFile(),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choisir un autre fichier'),
                    ),
                  ] else
                    FilledButton.icon(
                      onPressed: () => context.read<DatabaseProvider>().pickDatabaseFile(),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choisir un fichier .mmb'),
                    ),
                  if (dbProvider.status == DbStatus.error) ...[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: AppTheme.negative, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            dbProvider.errorMessage ?? 'Erreur inconnue',
                            style: const TextStyle(color: AppTheme.negative),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
