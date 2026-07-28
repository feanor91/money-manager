# Roadmap

Idées et pistes pour la suite, non planifiées ni engagées - une liste de
courses, pas des engagements.

## Priorité maximale

- Ajouter un graphe de dépenses par catégorie 

## Récemment fait

- ~~Modes d'exécution auto des opérations récurrentes inversés~~ - **fait**.
  Vérifié dans le vrai code source MMEX (v1.9.2, `REPEAT_AUTO` +
  `billsdepositsdialog.cpp`) : +100 = "en attente de saisie du paiement"
  (demande confirmation), +200 = "exécution automatique" (silencieux). Notre
  code avait ces deux offsets **inversés** depuis le début - une opération
  mise en "silencieuse" dans l'appli demandait en réalité confirmation une
  fois relue selon la vraie sémantique MMEX, et inversement. Corrigé dans
  `lib/models/recurrence.dart` (`decodeRepeats`/`encodeRepeats`). Pas de
  migration automatique des opérations déjà enregistrées avec l'ancien
  mapping - à revérifier/réajuster manuellement au cas par cas.
- ~~Écran de gestion des catégories~~ - **fait**. Paramètres > Catégories :
  catégories mères en liste dépliable avec leurs sous-catégories, ajout
  (mère ou enfant), renommage, fusion (les opérations/échéances/budgets/
  tiers de la catégorie source basculent vers la catégorie conservée,
  puis la source est supprimée), et suppression bloquée avec explication
  quand la catégorie est encore utilisée quelque part - avec un "Archiver"
  proposé à la place (nouveau : bascule le flag ACTIVE existant de MMEX,
  la catégorie disparaît des listes de choix sans perdre son historique).
  La fusion est limitée aux catégories sans sous-catégorie (source), pour
  ne pas avoir à décider tout seul du sort de petites-catégories orphelines.
- ~~Périodicités manquantes dans les opérations récurrentes~~ - **fait**.
  En creusant (source MMEX stable v1.9.2, `Model_Billsdeposits.h`), le
  vrai souci était plus profond qu'un simple manque : notre code 4 était
  carrément **mal mappé** ("mensuel dernier jour" au lieu de "tous les 2
  mois"), ce qui faussait silencieusement la fréquence de 2 opérations
  réelles de la base de test (dont "Couverture pour Bitiba"). Corrigé,
  plus "dernier jour ouvré" (code 16), et les 4 périodicités restantes
  "dans/tous les (n) jours/mois" (codes 11-14) implémentées fidèlement au
  comportement MMEX d'origine (`Repeat::next_repeat`) : "dans X" = exactement
  2 occurrences espacées de X puis le modèle se supprime, "tous les X" =
  répétition infinie avec cet intervalle. Au passage, un vrai bug de
  dépassement a aussi été corrigé : le rattrapage ("catch-up") des
  opérations en retard pouvait générer plus de transactions qu'il ne
  restait d'occurrences à une opération à durée limitée, et la faisait
  ensuite passer illimitée par erreur.
- ~~Précision des dates pour "dernier jour du mois"/"dernier jour ouvré"~~ -
  **fait**. Chaque occurrence est désormais explicitement calée sur le
  vrai dernier jour calendaire du mois cible (et recule au vendredi si
  "dernier jour ouvré" tombe un week-end), au lieu de dériver depuis le
  jour d'origine.
- ~~Opérations récurrentes en pause~~ - **fait**. Case à cocher par
  opération, stockée dans `INFOTABLE_V1` (table clé-valeur déjà présente
  dans tout fichier `.mmb`, comme `BASECURRENCYID`) sous une clé dédiée -
  aucune modification du schéma `BILLSDEPOSITS_V1`, ça voyage avec le
  fichier et reste inoffensif pour MMEX desktop. Exclue de l'ajout
  automatique et du prévisionnel ; remontée en tête de liste pour rester
  facile à retrouver/réactiver.
- ~~Prévision de solde repensée~~ - **fait**. Le graphique part maintenant
  toujours d'aujourd'hui vers le futur (fini la navigation vers le passé),
  avec une durée choisie dans une liste (1/2/3/6 mois, 1 an) au lieu des
  boutons jour/semaine/mois. Ajout d'une simulation "et si" d'achat non
  prévu (comptant ou en 2 à 12 fois) affichée en surimpression, et de
  repères visuels (traits rouges, infobulle au survol avec le total si
  plusieurs opérations tombent le même jour) pour les opérations
  récurrentes à venir.
- ~~Solde prévisionnel à date fixe~~ - **fait**. Les bulles de compte et
  la bande de solde en haut du tableau de bord affichent maintenant, en
  plus du solde du jour, le solde projeté à un jour du mois configurable
  (Paramètres, "Jour de prévision du solde", 24 par défaut - la veille
  d'une paye le 25).
- ~~Thème clair/sombre~~ - **fait**, et élargi. 4 palettes de couleurs
  (Indigo/Emeraude/Ardoise/Ambre) pilotent l'échelle de surfaces "tonale"
  Material 3, donc le fond et les cartes se teintent vraiment (pas
  seulement les boutons comme dans un premier essai). "Systeme"/"Clair"/
  "Sombre" dans la même liste permettent de forcer manuellement la
  luminosité au lieu de dépendre uniquement du systeme - le sombre est un
  gris tres fonce, pas noir pur. Au passage, deux fonds de ligne codes en
  dur en blanc (grand livre des transactions, liste des comptes) qui
  cassaient le rendu en mode sombre ont ete corriges.
- ~~Vue tableau pour la prévision de solde~~ - **fait**. Bascule
  graphique/liste a cote du choix de duree : la liste presente chaque
  operation prevue (style grand livre des transactions), avec le solde
  du jour courant.

## Demandées

- **Système de budget simple et efficace** - le suivi actuel (Budget par
  catégorie) est basique ; à repenser une fois qu'on sait ce qu'on veut en
  tirer (alertes de dépassement ? report d'un mois sur l'autre ? budget
  par enveloppe ?). Prérequis naturel avant d'intégrer le budget dans la
  prévision de solde (voir README, limitations connues).
- **Application de bureau plus complète** - une version desktop (Windows/
  macOS/Linux, Flutter le permet déjà techniquement) avec plus d'écrans
  d'aide et de suivi que ce que l'interface mobile/web actuelle propose -
  reste à définir ce que "plus complet" veut dire concrètement.

## Suggestions (à valider avant de s'y lancer)

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
  français en dur dans le code (pas de fichiers `.arb`/`intl_*`).
  `flutter_localizations` a bien été ajouté depuis, mais uniquement pour
  forcer les widgets Material génériques (le calendrier de `showDatePicker`
  notamment, qui s'affichait en anglais) en français via `locale: Locale('fr')`
  - ça ne couvre pas le texte de l'appli elle-même. Passage en `l10n`
  standard Flutter à prévoir si l'app doit un jour servir à quelqu'un
  d'autre que son utilisateur actuel - gros travail mécanique (extraire
  toutes les chaînes) plutôt que complexe, mais pas prioritaire tant
  qu'il n'y a qu'un seul utilisateur francophone.

## Notes

Cette liste n'est pas priorisée. Pour lancer un chantier, il vaut mieux en
discuter d'abord (portée, maquette rapide si besoin) plutôt que de partir
directement sur l'implémentation - plusieurs demandes précédentes ont
changé de forme une fois qu'on voyait le résultat en pratique.
