# Roadmap

Idées et pistes pour la suite, non planifiées ni engagées - une liste de
courses, pas des engagements.

## Priorité maximale

- ~~Périodicités manquantes dans les opérations récurrentes~~ - **fait**.
  En creusant (source MMEX stable v1.9.2, `Model_Billsdeposits.h`), le
  vrai souci était plus profond qu'un simple manque : notre code 4 était
  carrément **mal mappé** ("mensuel dernier jour" au lieu de "tous les 2
  mois"), ce qui faussait silencieusement la fréquence de 2 opérations
  réelles de la base de test (dont "Couverture pour Bitiba"). Corrigé,
  plus "dernier jour ouvré" (code 16) ajouté. Reste non géré : les 4
  périodicités "dans/tous les (n) jours/mois" (codes 11-14) - elles
  réutilisent `NUMOCCURRENCES` comme paramètre `n` plutôt que comme
  compteur d'occurrences restantes, ce qui entre en conflit avec le champ
  "Durée limitée" existant et demande une vraie réflexion UI avant
  d'être ajoutées (aucune opération réelle ne les utilise actuellement,
  donc pas urgent).
- **Précision des dates pour "dernier jour du mois"/"dernier jour ouvré".**
  `_monthStepFor` avance juste d'un mois et laisse `_addMonths` caler sur
  le même jour du mois (avec clamp si le jour n'existe pas) - une
  opération démarrant un 30 dérivera au lieu de systématiquement retomber
  sur le vrai dernier jour de chaque mois (et "dernier jour ouvré" ne
  recule pas encore si ça tombe un week-end). Aucune opération réelle
  actuelle n'utilise ces deux périodicités, donc pas bloquant, mais à
  corriger avant de les recommander à l'usage.

## Demandées

- **Thème clair/sombre** (et peut-être d'autres palettes) - actuellement
  l'app suit `ThemeMode.system` mais n'a qu'un seul thème clair réellement
  soigné (`AppTheme.light()`) ; `AppTheme.dark()` existe mais mériterait
  une vraie passe de design, pas juste un thème Material par défaut.
- **Système de budget simple et efficace** - le suivi actuel (Budget par
  catégorie) est basique ; à repenser une fois qu'on sait ce qu'on veut en
  tirer (alertes de dépassement ? report d'un mois sur l'autre ? budget
  par enveloppe ?). Prérequis naturel avant d'intégrer le budget dans la
  prévision de solde (voir README, limitations connues).
- **Application de bureau plus complète** - une version desktop (Windows/
  macOS/Linux, Flutter le permet déjà techniquement) avec plus d'écrans
  d'aide et de suivi que ce que l'interface mobile/web actuelle propose -
  reste à définir ce que "plus complet" veut dire concrètement.
- **Vue tableau pour la prévision de solde** - en plus du graphique actuel,
  une vue tabulaire des mêmes données (date/solde projeté/origine), comme
  dans MMEX desktop. Plus facile à lire précisément qu'un graphique,
  complémentaire plutôt que remplaçant.

## Suggestions (à valider avant de s'y lancer)

- **Écran de gestion des catégories/payés** - actuellement seulement
  créables à la volée depuis l'éditeur de transaction (limitation déjà
  notée dans le README) ; un écran dédié permettrait de renommer,
  fusionner, désactiver.
- **Export CSV** des transactions (utile pour la déclaration d'impôts ou
  un tableur externe) - relativement simple à ajouter vu que le grand
  livre est déjà entièrement lisible via `MmexRepository`.
- **Rappels/notifications** pour les opérations récurrentes à venir
  (notification Android le jour J plutôt que seulement à l'ouverture de
  l'app).
- **Déverrouillage biométrique** (empreinte/visage) en plus ou à la place
  du code PIN, sur Android - `local_auth` package, s'intègre proprement à
  côté du `PinLockProvider` existant.
- **Bouton "Annuler la suppression"** pour une transaction (actuellement
  la suppression est immédiate et définitive, pas de confirmation ni de
  filet de rattrapage au-delà des sauvegardes automatiques).
- **Petit outil de diagnostic de la base** - un écran (ou une commande)
  listant les anomalies détectables (transactions `DELETEDTIME` fantômes,
  catégories orphelines, etc.) - on en a débusqué plusieurs à la main
  pendant le développement (voir historique des échanges sur le graphique
  de prévision), un outil dédié éviterait de recommencer ce travail
  d'enquête à chaque nouveau souci de solde qui ne correspond pas.
- **Tri/personnalisation des colonnes** du grand livre des transactions.

## Priorité basse

- **Localisation multilingue.** Toute l'interface est actuellement en
  français en dur dans le code (pas de fichiers `.arb`/`intl_*` ni de
  `flutter_localizations`). Passage en `l10n` standard Flutter à prévoir
  si l'app doit un jour servir à quelqu'un d'autre que son utilisateur
  actuel - gros travail mécanique (extraire toutes les chaînes) plutôt
  que complexe, mais pas prioritaire tant qu'il n'y a qu'un seul
  utilisateur francophone.

## Notes

Cette liste n'est pas priorisée. Pour lancer un chantier, il vaut mieux en
discuter d'abord (portée, maquette rapide si besoin) plutôt que de partir
directement sur l'implémentation - plusieurs demandes précédentes ont
changé de forme une fois qu'on voyait le résultat en pratique.
