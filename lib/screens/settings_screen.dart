import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/database_provider.dart';
import '../state/pin_lock_provider.dart';
import 'pin_lock_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final pinLock = context.watch<PinLockProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Parametres')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Code PIN'),
              subtitle: Text(pinLock.hasPin
                  ? 'Active - demande a chaque ouverture de l\'appli'
                  : 'Desactive - aucune protection a l\'ouverture'),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const PinSetupScreen())),
                    child: Text(pinLock.hasPin ? 'Modifier' : 'Definir'),
                  ),
                  if (pinLock.hasPin)
                    TextButton(
                      onPressed: () =>
                          context.read<PinLockProvider>().removePin(),
                      child: const Text('Supprimer'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Base de donnees active'),
              subtitle: Text(dbProvider.currentLabel ?? 'Aucune'),
              trailing: dbProvider.isDirectlyPersisted
                  ? const Tooltip(
                      message:
                          'Les modifications sont ecrites directement dans le fichier',
                      child: Icon(Icons.link, color: Colors.green),
                    )
                  : const Tooltip(
                      message:
                          'Modifications en memoire uniquement pour cette session',
                      child: Icon(Icons.link_off, color: Colors.orange),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_outlined),
              title: const Text('Jour de prevision du solde'),
              subtitle: const Text(
                  'Affiche aussi le solde previsionnel a ce jour du mois '
                  '(ex : 24, la veille de la paye le 25)'),
              trailing: DropdownButton<int>(
                value: dbProvider.forecastDay,
                items: [
                  for (var day = 1; day <= 31; day++)
                    DropdownMenuItem(value: day, child: Text('$day')),
                ],
                onChanged: (day) {
                  if (day != null) dbProvider.setForecastDay(day);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () =>
                context.read<DatabaseProvider>().pickDatabaseFile(),
            icon: const Icon(Icons.folder_open),
            label: const Text('Changer de fichier .mmb'),
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _exportCopy(context),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Telecharger une copie .mmb'),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  dbProvider.isDirectlyPersisted
                      ? 'Ce navigateur garde un lien direct vers votre fichier : chaque '
                          'modification est ecrite dans le vrai fichier .mmb sur votre disque, '
                          'comme sur l\'application native. Au prochain lancement, il suffira de '
                          'confirmer l\'acces au fichier (bouton "Reconnecter").'
                      : 'Ce navigateur ne permet pas de garder un lien direct vers un fichier '
                          '(uniquement pris en charge par Chrome/Edge) : la base est chargee en '
                          'memoire pour cette session uniquement. Pensez a "Telecharger une copie" '
                          'avant de fermer l\'onglet, sinon les modifications seront perdues.',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _exportCopy(BuildContext context) async {
    final dbProvider = context.read<DatabaseProvider>();
    final bytes = dbProvider.exportCurrentBytes();
    if (bytes == null) return;
    await FilePicker.saveFile(
      fileName: 'MyMoney_export.mmb',
      bytes: Uint8List.fromList(bytes),
    );
  }
}
