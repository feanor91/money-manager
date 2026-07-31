# Instructions for Claude

Money Manager: a Flutter app (web + Android) that reads/writes an MMEX
SQLite `.mmb` database directly, for a non-developer user who relies on
Claude for all implementation, testing, and deployment. Explain what
you're doing in plain terms - don't assume Flutter/Dart/git familiarity.

## Repo layout

- This repo (`App`) lives at `D:\Repos\MoneyManager\App`.
- The real financial database is `D:\Repos\MoneyManager\Bdd\MyMoney.mmb` -
  **never commit `Bdd/`** (it's outside this repo entirely, one level up).
- A reference clone of the upstream MMEX source lives at
  `D:\Repos\MoneyManager\moneymanagerex` - consult it (`Model_Billsdeposits.h`,
  `billsdepositsdialog.cpp`, `Repeat::next_repeat`, etc.) whenever a
  recurrence/date/status semantic is unclear instead of guessing - this
  codebase has been bitten before by silently-wrong assumptions about
  MMEX's own encoding (see CHANGELOG/ROADMAP for past incidents).

## Git workflow

- Never run `git config` - the user sets their own identity.
- Never force-push, `reset --hard`, or other destructive ops without
  explicit confirmation.
- **Never plain `git push`** - a CI pipeline auto-commits version bumps to
  `main`, so always `git fetch origin main && git rebase origin/main`
  immediately before pushing, every time.
- Create new commits rather than amending, per standard policy.

## Dev loop (before every restart)

1. `flutter analyze`
2. `flutter test`
3. Kill whatever's on port 8791: PowerShell
   `Get-NetTCPConnection -LocalPort 8791 -State Listen | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }`
   (kills by port, not process name - safer than searching for `dart.exe`,
   since `flutter run -d web-server` on Windows actually spawns
   `dartvm.exe`; a name-based kill anchored to `dart` alone silently
   misses it). Then confirm the port is actually free -
   `Get-NetTCPConnection -LocalPort 8791 -State Listen` should return
   nothing - before starting a new server. A stale process left listening
   keeps answering requests with the *old* build, which reads exactly
   like "the fix isn't taking effect" and has already cost real debugging
   time chasing a phantom.
4. `flutter run -d web-server --release --web-port 8791 --web-hostname 0.0.0.0`
   as a background Bash command, then Monitor/poll its output file for
   `is being served at` before opening the preview browser. **Always
   `--release`, never plain debug mode** - debug mode has repeatedly
   caused a `mouse_tracker.dart` assertion-failure loop that freezes
   click handling in the browser, confirmed via DevTools console errors
   and explicitly rejected by the user as unusable ("le mode debug ne
   marchait pas top top") - not a one-off fluke, it recurred. Release
   compiles noticeably slower (roughly 1-4 minutes depending on how much
   changed/is cached) - mention that when kicking one off so a normal
   wait isn't mistaken for a hang, and actually check the log/process
   (CPU usage, elapsed vs. typical duration) before concluding it's stuck
   rather than just waiting anxiously or restarting prematurely.
5. Never rely on a browser refresh alone to pick up code changes, and do
   this proactively after every edit rather than waiting to be reminded -
   the dev server itself must be killed and relaunched per step 3-4
   first, every time, or the user is just looking at a stale build.
6. If scripting a health check against the dev server, use a GET request
   (or just load the page normally) - a HEAD request (`curl -I`) reliably
   404s on this server even when the page loads fine via GET, and will
   send you chasing a fake bug.
7. Verify the change live before calling it done - this user cannot read
   a diff and judge correctness themselves.

## Deploy sequence (only when the user explicitly asks to deploy)

1. `flutter analyze` + `flutter test` clean.
2. Commit, `git fetch origin main` + `git rebase origin/main`, `git push`.
3. `flutter build web --release`.
4. `robocopy build\web \\Excelsior\web\mmex /MIR` - **exit code 1 means
   success** (files copied), only exit codes ≥8 are real robocopy
   failures. Don't treat 1 as an error.

## App-owned database schema

MMEX's own tables (`CHECKINGACCOUNT_V1`, `BILLSDEPOSITS_V1`,
`CATEGORY_V1`, etc.) are treated as read/write but not to be restructured.
The user has explicitly authorized adding **new** app-owned tables freely
when a feature needs storage MMEX's schema doesn't have - prefix them
`APP_` so they're obviously not part of MMEX if the file is ever opened
in the real desktop app. All are created via
`MmexRepository.ensureAppSchema()`, called on every database open
(`DatabaseProvider._swapDatabase`) - `CREATE TABLE IF NOT EXISTS` for new
tables, and guarded `ALTER TABLE ... ADD COLUMN` (wrapped in try/catch)
when adding columns to a table that might already exist with an older
shape on someone's already-open file. Existing examples:
`APP_BUDGET_ENVELOPES`, `APP_BILL_OCCURRENCE_TOTALS`,
`APP_TRANSACTION_BILL_LINKS`.

## Where app preferences/settings live

**Default rule going forward: any new preference or setting belongs in the
database's companion settings file, not in `AppPreferences`/device-local
storage - unless it falls in the narrow "must stay local" exception below.**
This was an explicit decision (2026-07-31) reversing the previous
per-device-preference design, after the user pointed out that a
device/browser-local PIN is pointless security: clearing browser site data
(or reinstalling the app) silently wipes it with no warning, and each
device/browser needed its own separate PIN and settings for what's
conceptually the same file.

- The companion file (`money_manager_settings.dat`, AES-encrypted like the
  portable-desktop prefs file - see `EncryptedFilePreferences` in
  `lib/state/app_preferences.dart`, shared by both) sits in the **same
  folder as the currently open `.mmb` file** - native via a plain sibling
  path (`lib/data/db_companion_settings.dart`'s `forNativePath`), web via
  the directory handle already requested alongside the main file (see
  `WebFileLink.ensureDirectoryPermission`/`readCompanionFile`/
  `writeCompanionFile`). Because it lives next to the database rather than
  in this device's own storage, it automatically follows the database
  everywhere that folder is synced to (this user's case: a Nextcloud-synced
  folder) - one PIN, one set of preferences, on every device/browser that
  opens that file, and it survives a "clear site data"/reinstall that would
  wipe device-local storage.
- Currently living there: PIN hash/salt + lockout settings
  (`PinLockProvider`), palette, theme mode, forecast day, selected account,
  hidden accounts, account display order (all in `DatabaseProvider`).
- **Must stay in `AppPreferences` (device-local) - not a style choice, a
  hard technical necessity**: which database path to reopen at startup, and
  (web) this browser's own remembered file/directory permissions. Both are
  inherently per-device (a synced folder mounts at a different local path
  per device; web File System Access permissions can't be exported/shared
  across browsers by design) and have to be resolved *before* the companion
  file's location is even known - there's no chicken-and-egg way around
  this.
- Consequence: `PinLockProvider` no longer has a standalone `load()` -
  `DatabaseProvider` calls `attachDatabase()` on it (wired in main.dart)
  every time the open database changes, and `app.dart`'s `_RootGate` now
  loads the database *before* checking the PIN gate (reversed from before),
  since there's nowhere to check a PIN against until a database - and
  therefore its companion file - is open. A first frame before any database
  opens (the picker screen) briefly shows the default theme/palette even if
  a database opened moments later customises it - unavoidable, since
  there's nowhere else to read a customised theme from that early.
- Web-specific edge case: if a database is open but its companion folder
  permission isn't available (declined, or lapsed), whether a PIN is even
  configured is genuinely unknown - `PinGateStatus.needsCompanionAccess`
  fails *closed* (blocks entry, offers a retry button) rather than silently
  proceeding as if no PIN existed. Don't "fix" this by making it fail open;
  that's the whole security property this design exists for.

## The #1 recurring bug class: forgetting to persist

On web, every repository mutation (insert/update/delete/reconcile/...)
**must** be followed by `context.read<DatabaseProvider>().touch()` (or
the local `dbProvider.touch()` already in scope). `touch()` is what
debounce-writes the database back to the real `.mmb` file via the File
System Access API handle - without it, a change only lives in the
in-memory sqlite db. Because every screen reads straight from that same
live db, a missed `touch()` call is **invisible during testing**: the
edit shows up immediately in the UI (proving nothing was actually
broken) while silently never reaching disk. This exact bug has bitten
real user data more than once (transaction editor's Save/Delete buttons,
categories' "add" buttons, inline category-create pickers). When adding
or reviewing any new write path, explicitly check the `touch()` call is
there - don't assume it from the UI updating correctly.

Related: `DatabaseProvider.saveError` surfaces write-*failure* (a red
banner app-wide) - don't remove that, it's the fix for a previous
silent-failure incident.

## Android release signing

The release APK is signed with a real, stable keystore - **not** the
default debug key. Without this, every CI run would sign with a
different random debug key (auto-generated per runner), and Android
would refuse to install a new release as an "update" over the last one
(signature mismatch), forcing a full uninstall before every reinstall -
this happened for real before the fix.

- The actual keystore lives at
  `D:\Repos\MoneyManager\android-signing\release.keystore.jks` (sibling
  to this repo, like `Bdd/` - never inside `App/`, never committed).
  Losing this file permanently breaks in-place updates for everyone who
  already has the app installed (they'd all need to uninstall once) -
  back it up.
- `android/key.properties` (gitignored) points a **local** build at that
  keystore - present on this machine, absent on a fresh checkout
  elsewhere (falls back to the debug key in that case, see
  `android/app/build.gradle.kts`).
- CI writes its own `android/key.properties` + `android/release.keystore.jks`
  fresh on every run, from four repo secrets
  (`ANDROID_KEYSTORE_BASE64`/`ANDROID_KEYSTORE_PASSWORD`/`ANDROID_KEY_ALIAS`/
  `ANDROID_KEY_PASSWORD`) - see the "Set up Android release signing" step
  in `.github/workflows/release.yml`. Never regenerate these secrets
  without also updating the local keystore file (or vice versa) - they
  must be the exact same key, or CI-built and locally-built releases
  will conflict with each other on-device the same way the debug-key bug
  used to.

## Known semantics worth remembering

- "Reste à vivre" (budget screen) is the real forecasted account balance
  (`repo.forecastAccountBalance`), **not** a sum of budget envelopes -
  this was explicitly corrected after user pushback; don't reintroduce
  budget-math for it.
- MMEX's `NUMOCCURRENCES` column on a limited-duration recurring bill
  counts *down* to zero as occurrences fire - it never remembers the
  original total. `APP_BILL_OCCURRENCE_TOTALS` stores that total
  separately, set once (`INSERT OR IGNORE`) the first time a bill gets a
  limited duration, never overwritten by later edits to the remaining
  count.
- Never have the real MMEX desktop app and this web app open on the same
  `.mmb` file at the same time - concurrent writes from two different
  programs can throw `InvalidStateError` (File System Access API
  detecting the file changed underneath it) and risk corrupting the
  SQLite file. If the user reports a save failure, ask whether MMEX
  desktop was open first.
- The web File System Access API never exposes a file's full filesystem
  path, by browser design - only its name. Don't attempt to surface a
  "full path" in Settings; explain the limitation instead.
- All user-facing text is French, with proper accents - when adding
  strings, get the accents right the first time rather than doing a
  separate cleanup pass later.

## Working style feedback

- **UI consistency across equivalent features.** A feature that is
  conceptually the same *kind* of thing as something already in the app
  (e.g. "edit this record") must behave identically, not just look
  similar - don't invent a new interaction pattern for something that
  already has an established one elsewhere. This was framed as a general
  rule after several wrong-guess iterations building the budget envelope
  edit interaction as something bespoke (AlertDialog vs bottom sheet,
  confirm-before-delete vs immediate delete, a pencil icon vs tapping the
  row) when the transaction/recurring-bill editors already fully
  specified the answer. The reference pattern (as of 2026-07-29,
  confirmed by the user against "Modifier la transaction"):
  - The record's full edit form is `showModalBottomSheet(isScrollControlled:
    true, ...)`, never a centered `AlertDialog` - dismiss-on-outside-tap
    is the sheet's own default, no explicit "Annuler" button needed.
  - No pencil/edit icon anywhere - tapping the row itself (in a
    list/ledger) opens the full edit sheet directly.
  - A field with its own "quick edit" shortcut (the ledger's Date or
    Amount columns) opens its own small single-field `AlertDialog` when
    tapped directly, separately from the rest of the row which still
    opens the full sheet - this is the **exception**, not the rule. Don't
    assume a new field needs a quick-edit shortcut unless there's a
    specific reason (the ledger's case: fixing a date/amount against a
    bank statement without opening the whole form) - ask if unsure.
  - Inside the full sheet: fields stacked top to bottom, then at the very
    bottom a `Row` with `TextButton('Supprimer')` (plain, not styled red)
    on the left, `Spacer()`, `FilledButton('Enregistrer')` on the right.
    Delete is immediate, no confirmation dialog - matches how casual the
    rest of the app is about undo (there is none yet; see ROADMAP.md's
    "Bouton Annuler la suppression").
  Before designing a new "add/edit X" surface: find the closest existing
  equivalent (search for `showModalBottomSheet` and the
  `Supprimer`/`Enregistrer` row) and copy it structurally rather than
  reasoning about it from scratch.
- Confirm date pickers on tap (see `lib/utils/date_picker.dart`) - the
  user explicitly rejected the extra "OK" step `showDatePicker` requires.
- No mouse-wheel horizontal scroll on the budget gauges - explicit
  arrow buttons instead (wheel = page scroll, not intuitive per the user).
- **Pending:** the budget simulator's period selector (BudgetScreen,
  "Simulation" mode) only offers 3/6/12 mois - add a "1 mois" option,
  ordered *before* "3 mois".
- Before implementing a design choice with real ambiguity (e.g. a new UI
  interaction, a "what should count as X" judgment call), ask first
  rather than guessing - several past features changed shape once the
  user saw a first attempt in practice. See ROADMAP.md's Notes section.
- **Design for Android from the start, not just desktop/web.** The
  category spend analyzer (`lib/widgets/category_spend_analyzer.dart`)
  was built with a fixed-width side panel and a `SegmentedButton` with
  long labels, side by side - fine on desktop, but on Android the
  SegmentedButton had no room and wrapped its text vertically letter by
  letter. Any new dialog/screen with side-by-side panels or multi-segment
  controls needs a narrow-screen path considered up front. This app
  already has a convention for it: a `LayoutBuilder` checking
  `constraints.maxWidth < 640` that swaps to a stacked/simplified layout
  (see `transactions_screen.dart`'s `_LedgerTable`/`_LedgerCards` split,
  and the fix applied to the analyzer - stacked panels, `SegmentedButton`
  → `DropdownButtonFormField` below that breakpoint).
