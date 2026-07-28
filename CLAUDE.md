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
4. `flutter run -d web-server --web-port 8791 --web-hostname 0.0.0.0` as a
   background Bash command, then Monitor/poll its output file for
   `is being served at` before opening the preview browser.
5. Verify the change live before calling it done - this user cannot read
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

- Confirm date pickers on tap (see `lib/utils/date_picker.dart`) - the
  user explicitly rejected the extra "OK" step `showDatePicker` requires.
- No mouse-wheel horizontal scroll on the budget gauges - explicit
  arrow buttons instead (wheel = page scroll, not intuitive per the user).
- Before implementing a design choice with real ambiguity (e.g. a new UI
  interaction, a "what should count as X" judgment call), ask first
  rather than guessing - several past features changed shape once the
  user saw a first attempt in practice. See ROADMAP.md's Notes section.
