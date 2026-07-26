# Roadmap

Idées et pistes pour la suite, non planifiées ni engagées - une liste de
courses, pas des engagements.

## Priorité maximale

- **Périodicités manquantes dans les opérations récurrentes.** MMEX
  desktop propose 16 fréquences (`REPEATS` codes 0-15) ; on n'en gère que
  0-10 dans `lib/models/recurrence.dart` (`RecurrencePeriod`). Manquent :
  - Dans (n) jours / Dans (n) mois (codes 11-12)
  - Tous les (n) jours / Tous les (n) mois (codes 13-14)
  - Mensuellement (dernier jour ouvré) (code 15, à distinguer de
    "dernier jour du mois" déjà géré, code 4)
  Les 4 premières demandent un paramètre `n` en plus du code de période -
  à vérifier dans le schéma MMEX où ce `n` est réellement stocké
  (`BILLSDEPOSITS_V1` n'a pas de colonne dédiée visible pour l'instant ;
  possiblement encodé différemment, à creuser côté source MMEX avant
  d'implémenter) plutôt que de deviner. Une opération créée dans MMEX
  desktop avec une de ces périodicités manquantes tombe actuellement sur
  le comportement par défaut ("Mensuelle") côté decode - à corriger en
  priorité pour ne pas fausser silencieusement la fréquence réelle.

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

## Notes

Cette liste n'est pas priorisée. Pour lancer un chantier, il vaut mieux en
discuter d'abord (portée, maquette rapide si besoin) plutôt que de partir
directement sur l'implémentation - plusieurs demandes précédentes ont
changé de forme une fois qu'on voyait le résultat en pratique.
