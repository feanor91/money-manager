import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../data/android_file_link.dart';
import '../data/blank_database.dart';
import '../data/db_backup.dart';
import '../data/db_companion_settings.dart';
import '../data/mmex_database.dart';
import '../data/mmex_repository.dart';
import '../data/web_file_link.dart';
import '../theme/app_theme.dart';
import 'app_preferences.dart';

/// True on Android specifically - deliberately not dart:io's Platform.isAndroid,
/// which would fail to compile for web (this file also compiles there).
/// defaultTargetPlatform is web-safe; kIsWeb is checked first everywhere
/// this is used since defaultTargetPlatform on web reflects the browser's
/// own OS, not "there is no native platform here".
bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Device/browser-local - deliberately the only thing left in
/// AppPreferences by this provider. Everything else (theme, forecast day,
/// selected/hidden accounts, account order, PIN) lives in the current
/// database's companion settings file instead (see db_companion_settings.dart
/// and CLAUDE.md) - but *which* database to reopen, and (web) this browser's
/// own file/folder permissions, are inherently per-device and have to be
/// resolved before that companion file's location is even known, so they
/// can't move there.
const _prefsKeyLastPath = 'mmex_last_db_path';

/// Turns an Android SAF read failure into an actionable French message.
/// `NetworkOnMainThreadException` here does NOT mean this app did networking
/// on its own main thread - it's a long-standing, still-open bug in
/// Nextcloud's Android app itself (nextcloud/android#12375, also hits
/// Signal: signalapp/Signal-Android#13296): reading a file through its
/// DocumentsProvider crashes on Nextcloud's own main thread. Confirmed on a
/// real device 2026-08-01 that this is NOT a "not cached yet" problem -
/// making the file available offline in Nextcloud first, or even airplane
/// mode, changes nothing. The only fix that actually worked: don't route
/// through the "Nextcloud" entry in the folder picker at all - sync the
/// folder to a real local folder via a separate app (FolderSync free tier,
/// or Autosync) and pick that local folder instead. See CLAUDE.md.
String _androidReadErrorMessage(Object e) {
  if (e.toString().contains('NetworkOnMainThreadException')) {
    return 'Nextcloud n\'a pas réussi à fournir ce fichier - bug connu et '
        'toujours non corrigé de l\'application Nextcloud elle-même, pas de '
        'Money Manager. Ça ne se résout pas en le rendant disponible '
        'hors-ligne dans Nextcloud (déjà testé, sans effet) : il faut '
        'éviter complètement l\'entrée "Nextcloud" de ce sélecteur. '
        'Installez une appli de synchronisation (FolderSync, gratuite, ou '
        'Autosync) réglée en mode bidirectionnel vers un vrai dossier '
        'local du téléphone, puis choisissez ce dossier local ici (sous '
        '"stockage interne", pas "Nextcloud").';
  }
  return e.toString();
}

/// Turns a web file-restore failure into an actionable French message. The
/// raw DOMException (e.g. "NotFoundError: A requested file or directory
/// could not be found...") is what a renamed/moved/deleted remembered file
/// throws - same underlying situation as the desktop "fichier introuvable"
/// message, just a different exception shape on web.
String _webReadErrorMessage(Object e) {
  if (e.toString().contains('NotFoundError')) {
    return 'Le fichier mémorisé est introuvable (renommé, déplacé ou '
        'supprimé depuis la dernière fois). Choisissez-le à nouveau sous '
        'son nouveau nom/emplacement, ou un autre fichier.';
  }
  return e.toString();
}

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
  /// Called whenever this provider's notion of "which database, with which
  /// companion settings" changes - see [_applyCompanionSettings]. Wired in
  /// main.dart to PinLockProvider.attachDatabase, so the PIN gate always
  /// reflects whichever database is actually open right now rather than a
  /// stale one.
  final void Function({
    required bool databaseReady,
    required AppPreferences? companionPrefs,
    bool companionUnreachable,
  }) onDatabaseContextChanged;

  DatabaseProvider({required this.onDatabaseContextChanged}) {
    AppTheme.applyPalette(palette);
  }

  MmexDatabase? _db;
  MmexRepository? _repository;
  WebFileLink? _webFileLink;
  AndroidFileLink? _androidFileLink;
  DbStatus status = DbStatus.none;
  String? errorMessage;
  String? currentLabel;

  /// Web only: set when [status] is [DbStatus.needsReconnect], so the UI can
  /// say which file needs reconnecting.
  String? reconnectFileName;

  /// True once this session has actually written to the real file on disk
  /// at least once (desktop always; web/Android only with a live file link
  /// - see WebFileLink/AndroidFileLink). Purely informational, e.g. to
  /// explain why "Telecharger une copie" may or may not be necessary.
  bool get isDirectlyPersisted =>
      _isAndroid ? _androidFileLink != null : (!kIsWeb || _webFileLink != null);

  /// The current database's companion settings (see
  /// db_companion_settings.dart) - null if none is open, or (web) if its
  /// companion file isn't reachable yet (see [companionNeedsAccess]).
  AppPreferences? companionSettings;

  /// Web only: true when a database is open through a File System Access
  /// handle but its companion settings file isn't reachable yet (folder
  /// permission never granted or since revoked) - the UI should offer
  /// [retryCompanionAccess] rather than silently proceeding as if nothing
  /// were configured.
  bool companionNeedsAccess = false;

  /// Web only: re-requests the companion folder permission (see
  /// WebFileLink.ensureDirectoryPermission) and retries loading the
  /// companion settings - must be called directly from a user gesture.
  Future<void> retryCompanionAccess() async {
    final link = _webFileLink;
    if (link == null) return;
    final granted = await link.ensureDirectoryPermission();
    if (!granted) return;
    final prefs = await DatabaseCompanionSettings.forWebLink(link);
    await _applyCompanionSettings(prefs, webLinkAvailableButUnreachable: prefs == null);
    notifyListeners();
  }

  /// Account currently "in focus" on the dashboard. Persisted (in the
  /// current database's companion settings) so it's remembered next time
  /// this same database is opened.
  int? selectedAccountId;

  Future<void> selectAccount(int? accountId) async {
    selectedAccountId = accountId;
    notifyListeners();
    final prefs = companionSettings;
    if (prefs == null) return;
    if (accountId == null) {
      await prefs.remove(_prefsKeySelectedAccount);
    } else {
      await prefs.setInt(_prefsKeySelectedAccount, accountId);
    }
  }

  /// Accounts hidden from the dashboard and account-selection lists. Only
  /// the Accounts screen can toggle it back.
  Set<int> hiddenAccountIds = {};

  bool isAccountHidden(int accountId) => hiddenAccountIds.contains(accountId);

  Future<void> setAccountHidden(int accountId, bool hidden) async {
    if (hidden) {
      hiddenAccountIds.add(accountId);
    } else {
      hiddenAccountIds.remove(accountId);
    }
    notifyListeners();
    final prefs = companionSettings;
    if (prefs == null) return;
    await prefs.setStringList(_prefsKeyHiddenAccounts,
        hiddenAccountIds.map((id) => id.toString()).toList());
  }

  /// Custom account display order (list of account ids), used by the
  /// dashboard's drag-and-drop carousel. Accounts not present in this list
  /// (new ones, or before it's ever been set) fall back to their natural
  /// order.
  List<int> accountOrder = [];

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
    final prefs = companionSettings;
    if (prefs == null) return;
    await prefs.setStringList(
        _prefsKeyAccountOrder, orderedIds.map((id) => id.toString()).toList());
  }

  /// Day of month for the extra "solde previsionnel" figure shown on each
  /// account card (e.g. 24, the day before a salary lands on the 25th) -
  /// configurable since that date is different for everyone.
  int forecastDay = 24;

  Future<void> setForecastDay(int day) async {
    forecastDay = day.clamp(1, 31);
    notifyListeners();
    final prefs = companionSettings;
    if (prefs == null) return;
    await prefs.setInt(_prefsKeyForecastDay, forecastDay);
  }

  /// Accent-color palette (see [AppTheme.applyPalette]). Starts at the
  /// default until a database's companion settings load (there is, by
  /// construction, nowhere else to read a customised palette from before
  /// then) - so the very first frame (database picker, etc.) may briefly
  /// show the default palette even if a database opened moments later
  /// customises it.
  AppPalette palette = AppPalette.indigo;

  Future<void> setPalette(AppPalette newPalette) async {
    palette = newPalette;
    AppTheme.applyPalette(newPalette);
    notifyListeners();
    final prefs = companionSettings;
    if (prefs == null) return;
    await prefs.setString(_prefsKeyPalette, newPalette.name);
  }

  /// Light/dark override - defaults to following the OS/browser setting,
  /// but can be forced either way (e.g. picking "Sombre" from the theme
  /// list even while the system itself is in light mode). Same
  /// loaded-with-the-database rationale as [palette].
  ThemeMode themeMode = ThemeMode.system;

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = companionSettings;
    if (prefs == null) return;
    await prefs.setString(_prefsKeyThemeMode, mode.name);
  }

  MmexRepository? get repository => _repository;
  bool get isReady => status == DbStatus.ready && _repository != null;

  /// Reopens the last used database: by path on desktop (re-read fresh from
  /// disk every time), by remembered File System Access handle on web, or
  /// by remembered Storage Access Framework folder grant on Android. Never
  /// falls back to a cached byte snapshot - if nothing can be reopened
  /// live, the picker screen is shown instead.
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
            await _finishOpeningWeb(db, link);
          } catch (e) {
            status = DbStatus.error;
            errorMessage = _webReadErrorMessage(e);
          }
          notifyListeners();
          return;
      }
    }

    if (_isAndroid) {
      // No "needs reconnect" state here unlike web - a persistable SAF
      // grant survives across launches on its own; if it's ever gone
      // (revoked, or the folder itself moved/deleted), tryRestore just
      // returns null and the picker screen shows, same as never having
      // opened anything - the user only needs to pick the folder again.
      final link = await AndroidFileLink.tryRestore();
      if (link == null) return;
      status = DbStatus.loading;
      notifyListeners();
      try {
        final bytes = await link.readBytes();
        final db = await MmexDatabase.openFromBytes(bytes, label: link.name);
        await _finishOpeningAndroid(db, link);
      } catch (e) {
        status = DbStatus.error;
        errorMessage = _androidReadErrorMessage(e);
      }
      notifyListeners();
      return;
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
      await _finishOpeningWeb(db, link);
    } catch (e) {
      status = DbStatus.error;
      errorMessage = _webReadErrorMessage(e);
    }
    notifyListeners();
  }

  Future<void> openFromPath(String path,
      {bool persist = true, String? notFoundMessage}) async {
    status = DbStatus.loading;
    notifyListeners();
    try {
      final db = await MmexDatabase.openFromPath(path);
      if (persist) {
        final prefs = await AppPreferences.getInstance();
        await prefs.setString(_prefsKeyLastPath, path);
      }
      await _finishOpeningNative(db);
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
      // No WebFileLink in this fallback path at all (plain <input type=file>
      // byte read, used when the browser lacks File System Access support,
      // or on native when this is called some other way) - there's no
      // mechanism to reach a companion file, so treat it like "no companion
      // settings possible" rather than a recoverable "needs access" state.
      await _applyCompanionSettings(null, webLinkAvailableButUnreachable: false);
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
  /// byte read otherwise. On Android, always goes through the Storage
  /// Access Framework folder picker (see AndroidFileLink) rather than
  /// FilePicker.pickFiles below - that call hands back a path to a private
  /// cache copy on Android, never the real file (see CLAUDE.md/ROADMAP.md),
  /// which is exactly the bug this whole path exists to avoid.
  Future<void> pickDatabaseFile() async {
    if (kIsWeb && WebFileLink.isSupported) {
      final link = await WebFileLink.pickAndRemember();
      if (link == null) return; // user cancelled
      status = DbStatus.loading;
      notifyListeners();
      try {
        final bytes = await link.readBytes();
        final db = await MmexDatabase.openFromBytes(bytes, label: link.name);
        await _finishOpeningWeb(db, link);
      } catch (e) {
        status = DbStatus.error;
        errorMessage = e.toString();
      }
      notifyListeners();
      return;
    }

    if (_isAndroid) {
      AndroidFileLink? link;
      try {
        link = await AndroidFileLink.pickAndRemember();
      } catch (e) {
        status = DbStatus.error;
        errorMessage = e.toString();
        notifyListeners();
        return;
      }
      if (link == null) return; // user cancelled the folder picker
      status = DbStatus.loading;
      notifyListeners();
      try {
        final bytes = await link.readBytes();
        final db = await MmexDatabase.openFromBytes(bytes, label: link.name);
        await _finishOpeningAndroid(db, link);
      } catch (e) {
        status = DbStatus.error;
        errorMessage = _androidReadErrorMessage(e);
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

  /// Lets the user pick where to create a brand-new, empty-but-functional
  /// .mmb file - the "New Database" counterpart to [pickDatabaseFile]'s
  /// "open an existing one". See [initializeBlankSchema] for what actually
  /// gets written. Not offered on Android for the same reason
  /// [pickDatabaseFile] needs AndroidFileLink - a plain save-file path
  /// there would be just as disconnected from real shared storage as the
  /// cache-copy bug this whole file works around.
  ///
  /// Web needed its own path here (added 2026-08-02, after a first-time web
  /// user with no existing .mmb had no way to get started at all - only
  /// "Choisir un fichier .mmb" was ever offered on web): there's no
  /// arbitrary filesystem path to hand `openFromPath`, so this instead asks
  /// the browser's own save-file picker where to put it, builds the blank
  /// schema in the same in-memory sqlite3 (wasm) database `openFromBytes`
  /// always uses on web, then writes those bytes to the chosen location.
  Future<void> createNewDatabase() async {
    if (_isAndroid) return;
    if (kIsWeb) {
      if (!WebFileLink.isSupported) return;
      final link = await WebFileLink.pickLocationForNewFile('MaBanque.mmb');
      if (link == null) return; // user cancelled
      status = DbStatus.loading;
      notifyListeners();
      try {
        final db = await MmexDatabase.openFromBytes(const [], label: link.name);
        await initializeBlankSchema(db);
        await link.writeBytes(db.exportBytes());
        await _finishOpeningWeb(db, link);
      } catch (e) {
        status = DbStatus.error;
        errorMessage = e.toString();
      }
      notifyListeners();
      return;
    }
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
      final db = await MmexDatabase.openFromPath(path, createIfMissing: true);
      await initializeBlankSchema(db);
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_prefsKeyLastPath, path);
      await _finishOpeningNative(db);
    } catch (e) {
      status = DbStatus.error;
      errorMessage = e.toString();
    }
    notifyListeners();
  }

  Timer? _writeBackDebounce;

  /// Set when the last attempt to write back to the real file on disk
  /// (web/Android, through a live file link) failed - e.g. permission
  /// silently revoked, the file locked by another program, disk full. Null
  /// means either persistence isn't applicable (desktop, or no link) or
  /// the last write succeeded. Surfaced app-wide (see [HomeShell]) because
  /// a failed save must never happen invisibly - the previous behaviour
  /// let a write fail with nobody ever finding out.
  String? saveError;

  Future<void> _writeBackWeb(WebFileLink link, MmexDatabase db) async {
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

  Future<void> _writeBackAndroid(AndroidFileLink link, MmexDatabase db) async {
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

  /// Serializes every write-back attempt (debounced, or a manual
  /// "Réessayer") so at most one is ever actually talking to the file
  /// handle at a time. Two `createWritable()` calls open at once on the
  /// same handle is exactly what throws the File System Access API's
  /// "state cached... changed since read from disk" InvalidStateError -
  /// confirmed 2026-08-03: it surfaced during a burst of rapid deletes,
  /// each one's debounced write starting before the previous one had
  /// finished exporting+writing the whole database. The debounce timer
  /// below only delays *starting* the next write; this is what actually
  /// keeps two of them from running concurrently once they do start.
  Future<void> _writeBackChain = Future.value();
  bool _writeInFlight = false;

  /// True while there's real risk of losing the most recent edit(s) if the
  /// tab/window closed right now: either a debounced write hasn't started
  /// yet, or one is actively running. Web-only in practice (desktop/Android
  /// don't debounce a write-back at all - see [touch]) - see
  /// unsaved_changes_guard.dart, which warns before closing exactly when
  /// this is true.
  bool get hasPendingWrite => _writeBackDebounce != null || _writeInFlight;

  void _enqueueWriteBack(Future<void> Function() writeBack) {
    _writeBackChain = _writeBackChain.then((_) async {
      _writeInFlight = true;
      // Notify right at the start/end of the actual write (not just when
      // it's scheduled) so a UI indicator tied to hasPendingWrite can show
      // "saving now" rather than only "something changed at some point".
      notifyListeners();
      try {
        await writeBack();
      } finally {
        _writeInFlight = false;
      }
    });
  }

  /// Re-attempts the last failed write-back after [saveError] was shown to
  /// the user (e.g. a "Réessayer" button), using the current in-memory
  /// state of the database (not just re-running the old attempt).
  void retrySave() {
    final db = _db;
    if (db == null) return;
    final webLink = _webFileLink;
    final androidLink = _androidFileLink;
    if (webLink != null) {
      _enqueueWriteBack(() => _writeBackWeb(webLink, db));
    } else if (androidLink != null) {
      _enqueueWriteBack(() => _writeBackAndroid(androidLink, db));
    }
  }

  /// Call after any repository write (insert/update/delete/reconcile/...):
  /// every screen watches this provider, so this is what makes sibling tabs
  /// kept alive by the bottom navigation's IndexedStack refresh their data.
  ///
  /// On web (File System Access handle) or Android (Storage Access
  /// Framework grant), this is also what writes the change straight back to
  /// the real file on disk (debounced), so it's still there next time the
  /// file is reopened - exactly like desktop.
  void touch() {
    notifyListeners();
    final db = _db;
    if (db == null) return;
    final webLink = _webFileLink;
    final androidLink = _androidFileLink;
    if (webLink != null) {
      _writeBackDebounce?.cancel();
      _writeBackDebounce = Timer(const Duration(milliseconds: 500), () {
        _enqueueWriteBack(() => _writeBackWeb(webLink, db));
      });
    } else if (androidLink != null) {
      _writeBackDebounce?.cancel();
      _writeBackDebounce = Timer(const Duration(milliseconds: 500), () {
        _enqueueWriteBack(() => _writeBackAndroid(androidLink, db));
      });
    }
  }

  /// Raw bytes of the currently open database, e.g. to offer a download on
  /// web so changes can be synced back into the real .mmb file by hand.
  List<int>? exportCurrentBytes() => _db?.exportBytes();

  /// A dated snapshot of whatever was just opened, before any edits this
  /// session could touch it - a safety net independent of the user's own
  /// backup habits. Must be called after [_webFileLink]/[_androidFileLink]
  /// reflects the link (if any) just established, since web/Android
  /// backups are written through it. Never lets a backup failure (revoked
  /// folder access, read-only disk, quota) block the app from being usable.
  void _backupNow(MmexDatabase db) {
    final bytes = db.exportBytes();
    if (kIsWeb) {
      final link = _webFileLink;
      if (link == null) return;
      unawaited(
          link.writeBackup(bytes, backupFileName(db.label)).catchError((_) {}));
    } else if (_isAndroid) {
      final link = _androidFileLink;
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
  }

  /// Desktop: finishes opening [db] - companion settings come from a
  /// sibling file next to it, always reachable (no permission to lack).
  Future<void> _finishOpeningNative(MmexDatabase db) async {
    await _swapDatabase(db);
    _backupNow(db);
    final prefs = await DatabaseCompanionSettings.forNativePath(db.label);
    await _applyCompanionSettings(prefs);
    status = DbStatus.ready;
  }

  /// Web: finishes opening [db] through [link] - companion settings come
  /// from a file in whatever directory [link] has permission to (may be
  /// none yet, see [companionNeedsAccess]).
  Future<void> _finishOpeningWeb(MmexDatabase db, WebFileLink link) async {
    await _swapDatabase(db);
    _webFileLink = link;
    _backupNow(db);
    final prefs = await DatabaseCompanionSettings.forWebLink(link);
    await _applyCompanionSettings(prefs, webLinkAvailableButUnreachable: prefs == null);
    status = DbStatus.ready;
  }

  /// Android: finishes opening [db] through [link] - companion settings
  /// come from a file in the same Storage Access Framework folder [link]
  /// was granted (see AndroidFileLink), mirroring [_finishOpeningWeb]:
  /// web's File System Access API and Android's SAF are the same shape of
  /// constraint (no plain file path, but a real folder grant once
  /// obtained), unlike desktop's [_finishOpeningNative].
  Future<void> _finishOpeningAndroid(MmexDatabase db, AndroidFileLink link) async {
    await _swapDatabase(db);
    _androidFileLink = link;
    _backupNow(db);
    final prefs = await DatabaseCompanionSettings.forAndroidLink(link);
    await _applyCompanionSettings(prefs);
    status = DbStatus.ready;
  }

  /// Central point where every "a database (with these companion settings)
  /// is now open" transition happens - (re)loads every preference this
  /// database's companion file holds (or resets to defaults if [prefs] is
  /// null), and tells [onDatabaseContextChanged] so PinLockProvider's PIN
  /// gate reflects this exact database rather than whatever the previously
  /// open one had.
  Future<void> _applyCompanionSettings(AppPreferences? prefs,
      {bool webLinkAvailableButUnreachable = false}) async {
    companionSettings = prefs;
    companionNeedsAccess = webLinkAvailableButUnreachable && prefs == null;

    if (prefs != null) {
      selectedAccountId = prefs.getInt(_prefsKeySelectedAccount);
      hiddenAccountIds = (prefs.getStringList(_prefsKeyHiddenAccounts) ?? [])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toSet();
      accountOrder = (prefs.getStringList(_prefsKeyAccountOrder) ?? [])
          .map((s) => int.tryParse(s))
          .whereType<int>()
          .toList();
      forecastDay = prefs.getInt(_prefsKeyForecastDay) ?? 24;
      palette = AppPalette.values.firstWhere(
        (p) => p.name == prefs.getString(_prefsKeyPalette),
        orElse: () => AppPalette.indigo,
      );
      themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == prefs.getString(_prefsKeyThemeMode),
        orElse: () => ThemeMode.system,
      );
    } else {
      // No companion settings reachable (yet, or ever, for this database) -
      // reset to defaults rather than keep showing whatever the previously
      // open database had configured.
      selectedAccountId = null;
      hiddenAccountIds = {};
      accountOrder = [];
      forecastDay = 24;
      palette = AppPalette.indigo;
      themeMode = ThemeMode.system;
    }
    AppTheme.applyPalette(palette);

    onDatabaseContextChanged(
      databaseReady: true,
      companionPrefs: prefs,
      companionUnreachable: companionNeedsAccess,
    );
  }

  @override
  void dispose() {
    _writeBackDebounce?.cancel();
    _db?.dispose();
    super.dispose();
  }
}

const _prefsKeySelectedAccount = 'mmex_selected_account_id';
const _prefsKeyHiddenAccounts = 'mmex_hidden_account_ids';
const _prefsKeyAccountOrder = 'mmex_account_order';
const _prefsKeyForecastDay = 'mmex_forecast_day';
const _prefsKeyPalette = 'mmex_app_palette';
const _prefsKeyThemeMode = 'mmex_app_theme_mode';
