# Changelog

Toutes les modifications notables de ce projet sont consignées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/).

## [1.0.22] - 2026-07-30

- fix(android): sign release APKs with a stable key instead of the debug key

## [1.0.21] - 2026-07-30

- fix(installer): install per-user, not per-machine
- feat(desktop): add Windows platform, installer, portable build, and encrypted portable prefs

## [1.0.20] - 2026-07-30

- feat(desktop): add Windows platform, installer, portable build, and encrypted portable prefs

## [1.0.19] - 2026-07-30

- feat(budget): add category spend analyzer for reliable budget adjustments
- docs(deploy skill): the work PC has no NAS access, skip the web mirror step there
- docs(claude.md): note the specific debug-mode bug and release-build timing
- docs(claude.md): add explicit port-free verification step to the dev loop
- docs(claude.md): spell out the edit-sheet UI pattern in full
- docs(claude.md): fold in dev-server gotchas from the other machine's session

## [1.0.18] - 2026-07-29

- feat(diagnostics): add read-only database integrity report

## [1.0.17] - 2026-07-29

- feat(budget): redesign as ranked bar chart, rename/delete envelopes, add transaction tooltips
- docs: add CLAUDE.md with project conventions and gotchas

## [1.0.16] - 2026-07-28

- feat(transactions,recurring): inline amount edit, recurring badge with occurrence count, quick recurring creation from ledger

## [1.0.15] - 2026-07-28

- fix(persistence): save/delete on transactions & recurring bills never wrote back to disk

## [1.0.14] - 2026-07-28

- feat(transactions): auto-confirm date picker, reconciled checkbox, account preselect; fix French accents app-wide

## [1.0.13] - 2026-07-28

- feat(budget): rebuild budget as per-account envelopes with auto-suggestions

## [1.0.12] - 2026-07-28

- feat(categories): category management screen, transaction search, fix auto-execute mapping

## [1.0.11] - 2026-07-27

- ci: skip build/release pipeline for doc-only commits
- fix(layout): dashboard crash on unbounded height, ledger row overflow

## [1.0.10] - 2026-07-27

- fix(layout): dashboard crash on unbounded height, ledger row overflow

## [1.0.9] - 2026-07-27

- Modif roadmap

## [1.0.8] - 2026-07-27

- roadmap: mark theme and forecast tabular-view items as done
- fix(theme): stop hardcoding white row backgrounds in ledgers
- feat(theme): selectable colour palettes and forceable light/dark mode
- feat(forecast): add tabular view toggle for the balance forecast

## [1.0.7] - 2026-07-27

- roadmap: mark recurring-transaction and forecast items as done
- feat(forecast): future-only balance chart with purchase simulation and configurable forecast-day balance
- feat(l10n): add French localization for Material widgets (date picker)
- feat(recurring): implement missing periodicities, fix catch-up overshoot, add pause toggle

## [1.0.6] - 2026-07-26

- ci: replace fragile rebase-retry with reset-and-redo on push conflict

## [1.0.5] - 2026-07-26

- roadmap: flag missing recurrence periods as top priority

## [1.0.4] - 2026-07-26

- ci: retry push with rebase on non-fast-forward (avoid race with manual pushes)

## [1.0.3] - 2026-07-26

- ci: fix duplicated intro paragraph in generated CHANGELOG entries
- Add ROADMAP.md with post-1.0 ideas

## [1.0.2] - 2026-07-26

- ci: add workflow_dispatch trigger for manual testing
- Add CI pipeline: analyze, test, build, auto-version, changelog, release

## [1.0.1] - 2026-07-26

### Corrigé
- Les feuilles d'édition (transaction, opération récurrente) ne tenaient
  compte que du clavier pour leur marge basse, pas de la barre de
  navigation système Android - les boutons "Enregistrer"/"Supprimer"
  pouvaient se retrouver à moitié masqués.

## [1.0.0] - 2026-07-25

Première version : lecture/écriture directe d'une base
[MoneyManager Ex](https://moneymanagerex.org/) (`.mmb`, SQLite standard),
en Flutter web + Android.

### Ajouté
- Tableau de bord (style bento) : solde par compte, graphique de prévision
  de solde (glisser pour explorer passé/futur, projection future basée sur
  les transactions récurrentes planifiées), dépenses par catégorie du mois,
  transactions récentes.
- Grand livre des transactions façon MMEX (colonnes Date/Tiers/Statut/
  Catégorie/Débit/Crédit/Solde/Remarques), avec solde courant par ligne,
  édition rapide de la date, pointage, et bascule automatique vers une vue
  en cartes sur petit écran.
- Opérations récurrentes : création/édition (y compris virements), durée
  limitée en nombre d'occurrences, remarque, rattrapage automatique des
  échéances passées à l'ouverture (silencieux ou avec confirmation),
  recherche plein texte et filtre par compte.
- Gestion des comptes : affichage/masquage, réordonnancement par
  glisser-déposer sur le tableau de bord.
- Suivi de budget par catégorie.
- Verrouillage par code PIN (hash salé, jamais stocké en clair),
  ré-activé automatiquement en arrière-plan sur mobile.
- Sauvegardes automatiques horodatées à chaque ouverture de la base
  (dossier `backups/` en natif, dossier `backup/` dans un répertoire
  autorisé par l'utilisateur sur le web).
- Web : lien direct et persistant vers le fichier `.mmb` (File System
  Access API, Chrome/Edge) permettant une écriture immédiate sur disque,
  comme en natif ; repli sur un export manuel pour les autres navigateurs.
- Design responsive (mobile/tablette/desktop) sur l'ensemble des écrans.
