import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../data/blank_database.dart';
import '../data/db_backup.dart';
import '../data/mmex_database.dart';
import '../data/mmex_repository.dart';
import '../data/web_file_link.dart';
import '../theme/app_theme.dart';
import 'app_preferences.dart';

const _prefsKeyLastPath = 'mmex_last_db_path';
const _prefsKeySelectedAccount = 'mmex_selected_account_id';
const _prefsKeyHiddenAccounts = 'mmex_hidden_account_ids';
const _prefsKeyAccountOrder = 'mmex_account_order';
const _prefsKeyForecastDay = 'mmex_forecast_day';
const _prefsKeyPalette = 'mmex_app_palette';
const _prefsKeyThemeMode = 'mmex_app_theme_mode';

enum DbStatus {
  none,
  loading,
  ready,
  error,

  /// Web only: a previously picked file is remembered, but the browser
  /// needs a fresh user gesture (a button tap) to re-grant access to it -
  /// see [DatabaseProvider.reconnectWebFile].
  needsReconnect,
}

/// Holds the currently opened MMEX database + repository, and lets the user
/// pick a different .mmb file location at any time from Settings.
///
/// On native/desktop, the file path is remembered and re-read live from
/// disk on every launch. On web, when the browser supports the File System
/// Access API (Chrome/Edge), the chosen file's handle is remembered too and
/// every edit is written straight back to the real file - otherwise (older
/// browsers, or if the user declines), the database only lives in memory
/// for that session. Nothing is ever cached as a byte snapshot: every read
/// goes through the live file, so the app can never show stale or
/// already-deleted data.
class DatabaseProvider extends ChangeNotifier {
  MmexDatabase? _db;
  MmexRepository? _repository;
  WebFileLink? _webFileLink;
  DbStatus status = DbStatus.none;
  String? errorMessage;
  String? currentLabel;

  /// Web only: set when [status] is [DbStatus.needsReconnect], so the UI can
  /// say which file needs reconnecting.
  String? reconnectFileName;

  /// True once this session has actually written to the real file on disk
  /// at least once (native always; web only with File System Access
  /// support). Purely informational, e.g. to explain why "Telecharger une
  /// copie" may or may not be necessary.
  bool get isDirectlyPersisted => !kIsWeb || _webFileLink != null;

  /// Account currently "in focus" on the dashboard. Persisted so it
  /// survives app restarts.
  int? selectedAccountId;
  bool _selectedAccountLoaded = false;

  /// Accounts hidden from the dashboard and account-selection lists. This
  /// is a local app preference (not written into the .mmb file itself), so
  /// it only applies on this device/browser. Only the Accounts screen can
  /// toggle it back.
  Set<int> hiddenAccountIds = {};
  bool _hiddenAccountsLoaded = false;

  bool isAccountHidden(int accountId) => hiddenAccountIds.contains(accountId);

  Future<void> setAccountHidden(int accountId, bool hidden) async {
    if (hidden) {
      hiddenAccountIds.add(accountId);
    } else {
      hiddenAccountIds.remove(accountId);
    }
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    await prefs.setStringList(_prefsKeyHiddenAccounts,
        hiddenAccountIds.map((id) => id.toString()).toList());
  }

  /// Custom account display order (list of account ids), used by the
  /// dashboard's drag-and-drop carousel. A local app preference, like
  /// [hiddenAccountIds]. Accounts not present in this list (new ones, or
  /// before it's ever been set) fall back to their natural order.
  List<int> accountOrder = [];
  bool _accountOrderLoaded = false;

  /// Sorts [accounts] according to the saved drag-and-drop order, appending
  /// any account not yet present in that order (e.g. newly created) at the
  /// end in their given order.
  List<T> sortByAccountOrder<T>(List<T> accounts, int Function(T) idOf) {
    final indexOf = {
      for (var i = 0; i < accountOrder.length; i++) accountOrder[i]: i
    };
    final sorted = [...accounts];
    sorted.sort((a, b) {
      final ia = indexOf[idOf(a)] ?? accountOrder.length;
      final ib = indexOf[idOf(b)] ?? accountOrder.length;
      return ia.compareTo(ib);
    });
    return sorted;
  }

  Future<void> setAccountOrder(List<int> orderedIds) async {
    accountOrder = orderedIds;
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    await prefs.setStringList(
        _prefsKeyAccountOrder, orderedIds.map((id) => id.toString()).toList());
  }

  /// Day of month for the extra "solde previsionnel" figure shown on each
  /// account card (e.g. 24, the day before a salary lands on the 25th) -
  /// configurable since that date is different for everyone. A local app
  /// preference, like [hiddenAccountIds].
  int forecastDay = 24;
  bool _forecastDayLoaded = false;

  Future<void> setForecastDay(int day) async {
    forecastDay = day.clamp(1, 31);
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    await prefs.setInt(_prefsKeyForecastDay, forecastDay);
  }

  /// Accent-color palette (see [AppTheme.applyPalette]). A pure device/UI
  /// preference, unrelated to any specific database, so - unlike the
  /// account-scoped settings above - it's loaded eagerly via [loadPalette]
  /// at app startup (see main.dart) rather than lazily on first database
  /// open, so the right colours are already in place for the very first
  /// frame (PIN screen, database picker, etc.).
  AppPalette palette = AppPalette.indigo;

  Future<void> loadPalette() async {
    final prefs = await AppPreferences.getInstance();
    final saved = prefs.getString(_prefsKeyPalette);
    palette = AppPalette.values.firstWhere(
      (p) => p.name == saved,
      orElse: () => AppPalette.indigo,
    );
    AppTheme.applyPalette(palette);
  }

  Future<void> setPalette(AppPalette newPalette) async {
    palette = newPalette;
    AppTheme.applyPalette(newPalette);
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(_prefsKeyPalette, newPalette.name);
  }

  /// Light/dark override - defaults to following the OS/browser setting,
  /// but can be forced either way (e.g. picking "Sombre" from the theme
  /// list even while the system itself is in light mode). Same
  /// eager-load-at-startup rationale as [palette].
  ThemeMode themeMode = ThemeMode.system;

  Future<void> loadThemeMode() async {
    final prefs = await AppPreferences.getInstance();
    final saved = prefs.getString(_prefsKeyThemeMode);
    themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(_prefsKeyThemeMode, mode.name);
  }

  MmexRepository? get repository => _repository;
  bool get isReady => status == DbStatus.ready && _repository != null;

  /// Reopens the last used database: by path on native/desktop (re-read
  /// fresh from disk every time), or by remembered File System Access
  /// handle on web. Never falls back to a cached byte snapshot - if
  /// nothing can be reopened live, the picker screen is shown instead.
  Future<void> restoreLastDatabase() async {
    if (kIsWeb) {
      // Earlier versions cached a full byte snapshot here, which could show
      // stale (or even already-deleted) data on reload. Clean up any
      // leftover snapshot from before that was removed.
      final prefs = await AppPreferences.getInstance();
      await prefs.remove('mmex_web_cache_b64');
      await prefs.remove('mmex_web_cache_label');

      final result = await WebFileLink.tryRestore();
      switch (result.status) {
        case WebFileRestoreStatus.none:
          return;
        case WebFileRestoreStatus.needsPermission:
          status = DbStatus.needsReconnect;
          reconnectFileName = result.pendingName;
          notifyListeners();
          return;
        case WebFileRestoreStatus.ready:
          final link = result.link!;
          status = DbStatus.loading;
          notifyListeners();
          try {
            final bytes = await link.readBytes();
            final db =
                await MmexDatabase.openFromBytes(bytes, label: link.name);
            await _swapDatabase(db);
            _webFileLink = link;
            _backupNow(db);
            status = DbStatus.ready;
          } catch (e) {
            status = DbStatus.error;
            errorMessage = e.toString();
          }
          notifyListeners();
          return;
      }
    }
    final prefs = await AppPreferences.getInstance();
    final lastPath = prefs.getString(_prefsKeyLastPath);
    if (lastPath == null) return;
    await openFromPath(lastPath, persist: false, notFoundMessage: 'lastPath');
  }

  /// Web only: re-requests permission for the remembered file. Must be
  /// called directly from a user gesture (e.g. a button's onPressed).
  Future<void> reconnectWebFile() async {
    status = DbStatus.loading;
    notifyListeners();
    final link = await WebFileLink.requestPermissionAndRestore();
    if (link == null) {
      status = DbStatus.needsReconnect;
      notifyListeners();
      return;
    }
    try {
      final bytes = await link.readBytes();
      final db = await MmexDatabase.openFromBytes(bytes, label: link.name);
      await _swapDatabase(db);
      _webFileLink = link;
      _backupNow(db);
      status = DbStatus.ready;
    } catch (e) {
      status = DbStatus.error;
      errorMessage = e.toString();
    }
    notifyListeners();
  }

  Future<void> openFromPath(String path,
      {bool persist = true, String? notFoundMessage}) async {
    status = DbStatus.loading;
    notifyListeners();
    try {
      final db = await MmexDatabase.openFromPath(path);
      await _swapDatabase(db);
      _backupNow(db);
      if (persist) {
        final prefs = await AppPreferences.getInstance();
        await prefs.setString(_prefsKeyLastPath, path);
      }
      status = DbStatus.ready;
    } catch (e) {
      status = DbStatus.error;
      errorMessage = notFoundMessage != null
          ? 'Le dernier fichier utilisé est introuvable (déplacé ou supprimé). Choisissez-en un autre.'
          : e.toString();
    }
    notifyListeners();
  }

  Future<void> openFromBytes(List<int> bytes, String label) async {
    status = DbStatus.loading;
    notifyListeners();
    try {
      final db = await MmexDatabase.openFromBytes(bytes, label: label);
      await _swapDatabase(db);
      _backupNow(db);
      status = DbStatus.ready;
    } catch (e) {
      status = DbStatus.error;
      errorMessage = e.toString();
    }
    notifyListeners();
  }

  /// Opens the platform file picker so the user can choose their .mmb file.
  /// On web, prefers the File System Access API (remembered + writable
  /// handle) when the browser supports it, falling back to a plain one-shot
  /// byte read otherwise.
  Future<void> pickDatabaseFile() async {
    if (kIsWeb && WebFileLink.isSupported) {
      final link = await WebFileLink.pickAndRemember();
      if (link == null) return; // user cancelled
      status = DbStatus.loading;
      notifyListeners();
      try {
        final bytes = await link.readBytes();
        final db = await MmexDatabase.openFromBytes(bytes, label: link.name);
        await _swapDatabase(db);
        _webFileLink = link;
        _backupNow(db);
        status = DbStatus.ready;
      } catch (e) {
        status = DbStatus.error;
        errorMessage = e.toString();
      }
      notifyListeners();
      return;
    }

    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choisir la base de données (.mmb)',
      type: FileType.custom,
      allowedExtensions: ['mmb', 'db', 'sqlite'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        status = DbStatus.error;
        errorMessage = 'Impossible de lire le fichier sélectionné.';
        notifyListeners();
        return;
      }
      _webFileLink = null;
      await openFromBytes(bytes, file.name);
    } else {
      final path = file.path;
      if (path == null) {
        status = DbStatus.error;
        errorMessage = 'Impossible de récupérer le chemin du fichier.';
        notifyListeners();
        return;
      }
      await openFromPath(path);
    }
  }

  /// Desktop only (native file paths required): lets the user pick where
  /// to create a brand-new, empty-but-functional .mmb file - the "New
  /// Database" counterpart to [pickDatabaseFile]'s "open an existing one".
  /// See [initializeBlankSchema] for what actually gets written.
  Future<void> createNewDatabase() async {
    if (kIsWeb) return;
    final path = await FilePicker.saveFile(
      dialogTitle: 'Créer une nouvelle base de données (.mmb)',
      fileName: 'MaBanque.mmb',
      type: FileType.custom,
      allowedExtensions: ['mmb'],
    );
    if (path == null) return;
    status = DbStatus.loading;
    notifyListeners();
    try {
      final db = await MmexDatabase.openFromPath(path);
      await initializeBlankSchema(db);
      await _swapDatabase(db);
      _backupNow(db);
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_prefsKeyLastPath, path);
      status = DbStatus.ready;
    } catch (e) {
      status = DbStatus.error;
      errorMessage = e.toString();
    }
    notifyListeners();
  }

  Timer? _writeBackDebounce;

  /// Set when the last attempt to write back to the real file on disk
  /// (web, File System Access handle) failed - e.g. permission silently
  /// revoked, the file locked by another program, disk full. Null means
  /// either persistence isn't applicable (native, or no handle) or the
  /// last write succeeded. Surfaced app-wide (see [HomeShell]) because a
  /// failed save must never happen invisibly - the previous behaviour let
  /// [writeBytes] fail with nobody ever finding out.
  String? saveError;

  Future<void> _writeBack(WebFileLink link, MmexDatabase db) async {
    try {
      await link.writeBytes(db.exportBytes());
      if (saveError != null) {
        saveError = null;
        notifyListeners();
      }
    } catch (e) {
      saveError = e.toString();
      notifyListeners();
    }
  }

  /// Re-attempts the last failed write-back after [saveError] was shown to
  /// the user (e.g. a "Réessayer" button), using the current in-memory
  /// state of the database (not just re-running the old attempt).
  void retrySave() {
    final link = _webFileLink;
    final db = _db;
    if (link != null && db != null) {
      unawaited(_writeBack(link, db));
    }
  }

  /// Call after any repository write (insert/update/delete/reconcile/...):
  /// every screen watches this provider, so this is what makes sibling tabs
  /// kept alive by the bottom navigation's IndexedStack refresh their data.
  ///
  /// On web with a File System Access handle, this is also what writes the
  /// change straight back to the real file on disk (debounced), so it's
  /// still there next time the file is reopened - exactly like native.
  void touch() {
    notifyListeners();
    final link = _webFileLink;
    final db = _db;
    if (link != null && db != null) {
      _writeBackDebounce?.cancel();
      _writeBackDebounce = Timer(const Duration(milliseconds: 500), () {
        unawaited(_writeBack(link, db));
      });
    }
  }

  /// Raw bytes of the currently open database, e.g. to offer a download on
  /// web so changes can be synced back into the real .mmb file by hand.
  List<int>? exportCurrentBytes() => _db?.exportBytes();

  Future<void> selectAccount(int? accountId) async {
    selectedAccountId = accountId;
    notifyListeners();
    final prefs = await AppPreferences.getInstance();
    if (accountId == null) {
      await prefs.remove(_prefsKeySelectedAccount);
    } else {
      await prefs.setInt(_prefsKeySelectedAccount, accountId);
    }
  }

  /// A dated snapshot of whatever was just opened, before any edits this
  /// session could touch it - a safety net independent of the user's own
  /// backup habits. Must be called after [_webFileLink] reflects the link
  /// (if any) just established, since web backups are written through it.
  /// Never lets a backup failure (revoked folder access, read-only disk,
  /// quota) block the app from being usable.
  void _backupNow(MmexDatabase db) {
    final bytes = db.exportBytes();
    if (kIsWeb) {
      final link = _webFileLink;
      if (link == null) return;
      unawaited(
          link.writeBackup(bytes, backupFileName(db.label)).catchError((_) {}));
    } else {
      unawaited(
          DbBackup.save(label: db.label, bytes: bytes).catchError((_) {}));
    }
  }

  Future<void> _swapDatabase(MmexDatabase db) async {
    _db?.dispose();
    _db = db;
    _repository = MmexRepository(db)..ensureAppSchema();
    currentLabel = db.label;
    saveError = null;

    if (!_selectedAccountLoaded) {
      final prefs = await AppPreferences.getInstance();
      selectedAccountId = prefs.getInt(_prefsKeySelectedAccount);
      _selectedAccountLoaded = true;
    }
    if (!_hiddenAccountsLoaded) {
      final prefs = await AppPreferences.getInstance();
      hiddenAccountIds = (prefs.getStringList(_prefsKeyHiddenAccounts) ?? [])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toSet();
      _hiddenAccountsLoaded = true;
    }
    if (!_accountOrderLoaded) {
      final prefs = await AppPreferences.getInstance();
      accountOrder = (prefs.getStringList(_prefsKeyAccountOrder) ?? [])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toList();
      _accountOrderLoaded = true;
    }
    if (!_forecastDayLoaded) {
      final prefs = await AppPreferences.getInstance();
      forecastDay = prefs.getInt(_prefsKeyForecastDay) ?? 24;
      _forecastDayLoaded = true;
    }
  }

  @override
  void dispose() {
    _writeBackDebounce?.cancel();
    _db?.dispose();
    super.dispose();
  }
}
