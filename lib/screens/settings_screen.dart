import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../state/database_provider.dart';
import '../state/pin_lock_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/local_llm_settings_card.dart';
import '../widgets/webdav_settings_card.dart';
import 'categories_screen.dart';
import 'database_diagnostics_screen.dart';
import 'pin_lock_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dbProvider = context.watch<DatabaseProvider>();
    final pinLock = context.watch<PinLockProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: dbProvider.companionSettings == null
                ? const ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Code PIN'),
                    subtitle: Text(
                        'Indisponible - ce navigateur ne permet pas d\'enregistrer '
                        'de réglages à côté de cette base.'),
                  )
                : ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Code PIN'),
                    subtitle: Text(pinLock.hasPin
                        ? 'Activé - demandé à chaque ouverture de l\'appli'
                        : 'Désactivé - aucune protection à l\'ouverture'),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const PinSetupScreen())),
                          child: Text(pinLock.hasPin ? 'Modifier' : 'Définir'),
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
              leading: const Icon(Icons.category_outlined),
              title: const Text('Categories'),
              subtitle: const Text('Ajouter, renommer, fusionner ou archiver'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CategoriesScreen()),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Diagnostic de la base'),
              subtitle: const Text('Recherche de références orphelines, doublons, incohérences...'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DatabaseDiagnosticsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Base de données active'),
              subtitle: Text(dbProvider.currentLabel ?? 'Aucune'),
              trailing: dbProvider.isDirectlyPersisted
                  ? const Tooltip(
                      message:
                          'Les modifications sont écrites directement dans le fichier',
                      child: Icon(Icons.link, color: Colors.green),
                    )
                  : const Tooltip(
                      message:
                          'Modifications en mémoire uniquement pour cette session',
                      child: Icon(Icons.link_off, color: Colors.orange),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          const WebDavSettingsCard(),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_outlined),
              title: const Text('Jour de prévision du solde'),
              subtitle: const Text(
                  'Affiche aussi le solde prévisionnel à ce jour du mois '
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.palette_outlined),
                      SizedBox(width: 12),
                      Text('Thème'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final palette in AppPalette.values)
                        _PaletteSwatch(
                          palette: palette,
                          selected: dbProvider.palette == palette,
                          onTap: () => dbProvider.setPalette(palette),
                        ),
                      _ThemeModeSwatch(
                        icon: Icons.brightness_auto_outlined,
                        label: 'Système',
                        selected: dbProvider.themeMode == ThemeMode.system,
                        onTap: () => dbProvider.setThemeMode(ThemeMode.system),
                      ),
                      _ThemeModeSwatch(
                        icon: Icons.light_mode_outlined,
                        label: 'Clair',
                        color: Colors.white,
                        selected: dbProvider.themeMode == ThemeMode.light,
                        onTap: () => dbProvider.setThemeMode(ThemeMode.light),
                      ),
                      _ThemeModeSwatch(
                        icon: Icons.dark_mode_outlined,
                        label: 'Sombre',
                        color: const Color(0xFF2A2E37),
                        iconColor: Colors.white,
                        selected: dbProvider.themeMode == ThemeMode.dark,
                        onTap: () => dbProvider.setThemeMode(ThemeMode.dark),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const LocalLlmSettingsCard(),
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
              label: const Text('Télécharger une copie .mmb'),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  dbProvider.isDirectlyPersisted
                      ? 'Ce navigateur garde un lien direct vers votre fichier : chaque '
                          'modification est écrite dans le vrai fichier .mmb sur votre disque, '
                          'comme sur l\'application native. Au prochain lancement, il suffira de '
                          'confirmer l\'accès au fichier (bouton "Reconnecter").'
                      : 'Ce navigateur ne permet pas de garder un lien direct vers un fichier '
                          '(uniquement pris en charge par Chrome/Edge) : la base est chargée en '
                          'mémoire pour cette session uniquement. Pensez à "Télécharger une copie" '
                          'avant de fermer l\'onglet, sinon les modifications seront perdues.',
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Center(child: _VersionLabel()),
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

/// Own small StatefulWidget (not folded into SettingsScreen, which is
/// Stateless) so PackageInfo.fromPlatform() is only ever fetched once, in
/// initState - inlining it as a FutureBuilder in SettingsScreen.build would
/// re-run the future (and briefly flash back to nothing) on every rebuild
/// this screen already gets from watching DatabaseProvider. Added as a
/// reliable fallback 2026-08-04 after the bottom-nav-bar version label
/// (home_shell.dart) was confirmed still invisible on a real Android device
/// even after an earlier positioning fix - a plain line in a scrollable
/// list has no equivalent risk of being laid out under a system bar.
class _VersionLabel extends StatefulWidget {
  const _VersionLabel();

  @override
  State<_VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<_VersionLabel> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_version == null) return const SizedBox.shrink();
    return Text(
      'Version $_version',
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteSwatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: palette.seed,
                shape: BoxShape.circle,
                border: selected
                    ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 2)
                    : null,
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 20)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(palette.label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Same swatch shape as [_PaletteSwatch], but for the two "Clair"/"Sombre"
/// forced-brightness options (plus "Systeme" to go back to following the
/// OS/browser) - shown in the same list since they're all just different
/// entries in "choose a theme" from the user's point of view, even though
/// under the hood they set different, independent bits of state (see
/// DatabaseProvider.themeMode vs .palette).
class _ThemeModeSwatch extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final Color iconColor;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeModeSwatch({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.iconColor = Colors.black54,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color ?? Colors.grey.shade200,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.grey.shade400,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
