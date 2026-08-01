# Roadmap

Idées et pistes pour la suite, non planifiées ni engagées - une liste de
courses, pas des engagements.

## Demandées

- **Assistant de création de base pour un nouvel utilisateur** (important,
  demandé le 2026-08-01, en vue d'un partage futur du logiciel avec
  d'autres personnes - pas pour l'utilisateur actuel). Actuellement,
  "Créer une nouvelle base" (desktop uniquement) ne demande rien du tout :
  elle crée silencieusement une base minimale vide (devise EUR, catégories
  par défaut MMEX - voir `blank_database.dart`), sans nom ni premier
  compte. Ça n'a de sens que pour quelqu'un qui sait déjà ce qu'il fait -
  pour un nouvel utilisateur, il faut au minimum lui demander un nom et le
  laisser créer un premier compte avant de le lâcher dans une appli vide.

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
- **Bouton "Annuler la suppression"** pour une transaction (la suppression
  demande maintenant confirmation - voir Récemment fait - mais reste
  définitive une fois confirmée, pas de filet de rattrapage au-delà des
  sauvegardes automatiques).
- **Tri/personnalisation des colonnes** du grand livre des transactions.
- Ne pas mettre toutes les fonctionnalité dans l'application Andoid, certaines ne sont pas nécessaire (budget, dépnses par catégorie
- ?...)

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

## Récemment fait

- ~~Renommer/déplacer la bdd (desktop) ouvrait une base vide sans prévenir~~ -
  **fait/corrigé**. Signalé le 2026-08-01 : après avoir renommé le fichier
  `.mmb`, l'appli de bureau s'ouvrait sur un écran vide sans jamais proposer
  de choisir le nouveau fichier. Cause réelle : `sqlite3.open()` crée
  silencieusement un fichier vide (sans aucune table MMEX) si le chemin
  n'existe plus, au lieu de signaler une erreur - exactement ce qui se
  passe en rouvrant le dernier chemin connu après un renommage/déplacement.
  Corrigé pour qu'un chemin manquant redemande clairement de choisir un
  fichier, comme prévu. Voir CLAUDE.md pour le détail technique.

- ~~Android : le fichier réel n'était jamais lu/écrit~~ - **fait et
  vérifié sur un vrai téléphone (2026-08-01)**, avec une découverte
  importante au passage : choisir le dossier via l'entrée "Nextcloud" du
  sélecteur Android (la liaison virtuelle de l'appli Nextcloud) fait
  planter la lecture (`NetworkOnMainThreadException`) - bug connu et
  toujours ouvert de l'appli Nextcloud elle-même, pas quelque chose que ce
  projet peut corriger (voir CLAUDE.md pour le détail complet et les
  tickets amont). La solution qui marche réellement : synchroniser le
  dossier vers un vrai dossier **local** du téléphone via une appli tierce
  (FolderSync gratuit, ou Autosync payant après 14 jours d'essai) en mode
  bidirectionnel, puis choisir ce dossier local (pas "Nextcloud") dans
  Money Manager - confirmé fonctionnel une fois ce contournement en place.
  Limite à connaître : contrairement au PC, la synchronisation de ces
  applis n'est pas instantanée (programmée ou manuelle) - une transaction
  saisie sur Android peut nécessiter une synchronisation manuelle avant de
  remonter vers le serveur. Découverte initiale importante en
  creusant une remarque sur les paramètres qui ne se retrouvaient pas
  identiques entre appareils : sur Android, choisir le fichier `.mmb`
  passait par un mécanisme qui en fait une copie invisible dans le cache
  privé de l'appli - toutes les lectures/écritures se faisaient sur cette
  copie, **jamais sur le vrai fichier synchronisé Nextcloud**, avec un
  vrai risque de perte silencieuse de données (cache vidé, appli
  réinstallée, fichier re-choisi = copie fraîche du fichier original figé,
  tout ce qui a été saisi sur Android entre-temps disparaît). Corrigé en
  passant par le Storage Access Framework (dossier entier, pas juste un
  fichier, pour pouvoir aussi écrire le fichier de paramètres à côté) via
  les packages `saf_util`/`saf_stream` - voir CLAUDE.md pour le détail
  technique complet. Au passage, la première version de ce correctif
  cassait silencieusement le web (une des nouvelles dépendances tire une
  bibliothèque incompatible) - repéré uniquement en revérifiant le build
  web après coup, corrigé en isolant le code Android dans un fichier à
  part. Web, Android et Windows compilent tous les trois avec succès après
  coup - et, comme décrit plus haut, le comportement runtime sur Android
  est maintenant confirmé (avec le contournement Nextcloud nécessaire).
- ~~Build desktop obsolète~~ - **fait**. Le dossier `dist/` contenait une
  build Windows figée au 30 juillet (v1.0.18), bien antérieure à la
  migration des paramètres compagnons (31 juillet) - ce qui explique
  pourquoi l'appli de bureau ne demandait plus le bon code PIN ni les bons
  comptes. Nouvelle build (portable + installeur) régénérée à jour.

- ~~Simulateur de budget : mois clos, récurrent, budget fixé, sous-catégories~~
  - **fait**. Chantier important sur le simulateur (scénarios) livré cet
  après-midi :
  - Les moyennes (et les 4 moyennes de référence 12/6/3/1 mois affichées
    lors de la saisie d'un montant) ne comptent plus jamais le mois en
    cours, incomplet par nature.
  - Une opération récurrente active prime désormais sur la moyenne
    historique pour le montant suggéré (dépenses et revenus), même règle
    que pour les suggestions d'enveloppes.
  - Nouveau : un scénario peut être "fixé" (bouton avec confirmation) -
    grave les montants simulés affichés, qui cessent alors de suivre
    automatiquement la moyenne/récurrent (seule une modification manuelle
    les change) ; réversible via "Défixer" (`FIXED_AT`/colonne `MANUAL`
    sur `APP_BUDGET_SCENARIO_AMOUNTS`). Le sélecteur de période reste
    utile même fixé : il pilote la comparaison "Réel" à côté.
  - Catégories ajoutables/retirables (bouton dédié, saisie du montant
    désormais toujours obligatoire, plus de valeur par défaut silencieuse)
    et catégories "virtuelles" (sans lien avec une vraie catégorie MMEX,
    id négatif - `APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES`) pour planifier
    un poste qui n'existe pas encore.
  - Sous-catégories réelles dépliables avec édition individuelle du
    montant (même principe qu'une catégorie mère), et sous-catégories
    virtuelles pour subdiviser artificiellement le total d'une catégorie
    qui mélange plusieurs sources (ex. deux salaires sous "Salaire",
    distingués seulement par tiers) - limite connue : cette subdivision
    reste côté "simulé" uniquement, le "Réel" ne peut pas être scindé
    sans créer de vraies sous-catégories MMEX et réaffecter les
    transactions.

- ~~Réaffectation en masse d'une catégorie + confirmation de suppression~~
  - **fait**. Changer la catégorie d'une transaction ou d'une opération
    récurrente propose désormais de l'appliquer aussi à toutes les
    opérations "identiques" du grand livre (même tiers, même ancienne
    catégorie - ou même paire de comptes source/destination pour un
    virement, qui n'a pas de tiers) : nombre trouvé affiché, à confirmer.
    Supprimer une transaction ou une opération récurrente demande
    maintenant confirmation (n'était pas le cas avant).

- ~~Petits ajustements~~ - **fait**. Numéro de version affiché en bas à
  droite de la barre de navigation ; bouton Paramètres accessible depuis
  les 5 onglets (avant : uniquement Accueil) ; filtre de compte de l'écran
  Récurrentes passé d'une liste déroulante pleine largeur à une icône en
  haut à droite, pour matcher Budget/Transactions.

- ~~Mode simulation de budget~~ - **fait**, sous la forme de scénarios
  nommés. Nouveau bouton "Simulation" dans l'écran Budget : plusieurs
  scénarios par compte (créer/renommer/supprimer/rappeler librement),
  chacun affichant toutes les catégories avec un historique réel -
  revenus et dépenses ensemble, contrairement aux enveloppes qui ne
  couvrent que les dépenses - avec la moyenne réelle mensuelle (période
  3/6/12 mois au choix) à côté d'un montant simulé modifiable librement,
  enregistré immédiatement mais totalement indépendant du vrai budget
  (tables `APP_BUDGET_SCENARIOS`/`APP_BUDGET_SCENARIO_AMOUNTS`, jamais
  `APP_BUDGET_ENVELOPES`). Survoler une barre montre les vraies
  transactions qui composent sa moyenne, même principe que les
  info-bulles déjà existantes ailleurs dans l'écran Budget. Au passage :
  un vrai bug préexistant découvert en écrivant les tests de cette
  fonctionnalité - "Créer une nouvelle base" (desktop) échouait
  silencieusement, corrigé (voir plus bas).

- ~~"Créer une nouvelle base" (desktop) cassée silencieusement~~ -
  **fait/corrigé**. Le découpage du schéma SQL vierge avalait le premier
  `CREATE TABLE` (celui du compte) avec le bloc de commentaires qui le
  précède, faisant échouer toute la création de base sans que rien ne
  soit jamais commité - découvert par hasard en testant le simulateur de
  budget ci-dessus, sans lien avec la demande initiale.

- ~~Ajouter un graphe de dépenses par catégorie~~ - **fait**, via la refonte
  du budget en enveloppes (voir plus bas) : l'écran Budget affiche un
  graphe en barres horizontales classées par dépense réelle, chaque barre
  à la même échelle pour comparer les catégories d'un coup d'œil (repère
  visuel pour le montant cible, halo rouge si dépassé). Intégré à l'écran
  Budget plutôt qu'un écran séparé - à redemander si un graphe indépendant
  du budget (sans lien avec les enveloppes/objectifs) est en fait ce qui
  était voulu.

- ~~Application de bureau plus complète~~ - **fait**. Ajout de la cible
  Windows desktop : build portable (ZIP, préférences chiffrées à côté de
  l'exécutable via un marqueur `portable.txt`) et installeur classique
  (Inno Setup, installation par utilisateur - pas de droits admin
  nécessaires, pas de raccourci perdu sur un bureau OneDrive), tous deux
  générés automatiquement par la pipeline CI et attachés à chaque
  release GitHub. Nouveau flux "Créer une nouvelle base" (desktop
  uniquement, nécessite un vrai chemin de fichier) : génère une base MMEX
  minimale mais fonctionnelle à partir d'un schéma vierge intégré à
  l'appli, avec des catégories par défaut traduites en français.

- ~~Historique des transactions plafonné à 300 lignes~~ - **fait/corrigé**.
  Le grand livre ne pouvait plus remonter au-delà des ~300 dernières
  transactions d'un compte - au-delà, impossible d'atteindre les
  opérations plus anciennes. Le vrai problème n'était pas le nombre de
  lignes affichées (déjà géré efficacement) mais le calcul du solde
  courant, qui reparcourait tout l'historique du compte à chaque
  rafraîchissement d'écran, quel que soit le nombre de lignes retournées -
  confirmé en pratique (blocage du navigateur après suppression du
  plafond). Corrigé en passant à un affichage par mois : solde de départ
  calculé via une requête SQL agrégée légère plutôt qu'en reconstruisant
  chaque transaction depuis le début, mois courant affiché par défaut,
  flèches précédent/suivant, listes déroulantes mois et année pour
  naviguer vite loin dans le passé, bouton "Aujourd'hui".

- ~~Diagnostic de la base : plusieurs faux positifs~~ - **fait/corrigé**.
  Le seuil de "doublons probables" est passé de 2 à 3 transactions
  identiques le même jour - 2 identiques est un cas normal et fréquent
  chez cet utilisateur (plusieurs abonnements/versements d'assurance au
  même montant), pas un signal fiable. `TOACCOUNTID` à -1 *ou* 0 (deux
  variantes de la convention MMEX "non applicable" sur une opération qui
  n'est pas un virement, vérifiées empiriquement sur la vraie base) n'est
  plus signalé à tort comme "compte de destination inattendu" - ça
  remontait quasiment toutes les opérations normales du compte. Correctif
  de mise en page au passage (la date d'une ligne se coupait mal sur deux
  lignes dans certains cas).

- ~~Code PIN et préférences vulnérables à un nettoyage du navigateur~~ -
  **fait/corrigé**. Chantier important : le code PIN (haché), le nombre de
  tentatives avant blocage, la durée du blocage, le thème, le jour de
  prévision du solde, le compte sélectionné/masqués et leur ordre vivent
  désormais dans un petit fichier chiffré à côté du fichier `.mmb` lui-même
  (`money_manager_settings.dat`) plutôt que dans le stockage local du
  navigateur/appareil. Un "clear site data" ou une réinstallation ne les
  efface donc plus, et un seul réglage protège le fichier partout où il
  est ouvert (utile ici : la base vit dans un dossier synchronisé
  Nextcloud). Seul ce qui ne peut techniquement pas être partagé (le
  chemin du fichier à ouvrir, les autorisations de dossier du navigateur)
  reste local par appareil - point que CLAUDE.md documente maintenant
  comme règle par défaut pour tout futur réglage. Un vrai trou de sécurité
  a été découvert et corrigé en cours de route : l'écran Paramètres, seul
  de l'appli accessible par une URL dédiée (`/settings`), pouvait être
  rouvert par un simple rafraîchissement de page sans jamais redemander le
  code PIN, contournant entièrement la protection - la vérification
  s'applique maintenant à toute route, pas seulement à l'écran d'accueil.

- ~~Code PIN sans limite de tentatives~~ - **fait**. Blocage temporaire
  après un nombre configurable d'essais incorrects (5 par défaut), avec
  une durée de blocage elle aussi configurable (1 minute par défaut) - les
  deux réglages se modifient depuis l'écran de définition du code PIN, en
  même temps que le code lui-même. Le blocage est persistant : fermer et
  rouvrir l'appli, ou changer d'appareil, ne permet pas de le contourner.

- ~~Système de budget simple et efficace~~ - **fait**. Refonte complète en
  enveloppes par compte : suggestions automatiques (opérations récurrentes
  
  + moyenne sur 1 an, avec alerte si une catégorie n'a plus bougé depuis
    
    > 90 jours), jauges verticales groupées par catégorie mère, suivi des
    > revenus (dépôts + virements entrants hors épargne), simulation d'achat
    > partagée avec le graphique de prévision, et "reste à vivre" basé sur le
    > vrai solde prévisionnel du compte (pas un calcul de budget). Table
    > `APP_BUDGET_ENVELOPES` créée dynamiquement à l'ouverture de n'importe
    > quel fichier `.mmb`.

- ~~Bug de perte de données silencieuse~~ - **fait/corrigé**. Les boutons
  Enregistrer/Supprimer des fiches transaction et opération récurrente
  n'appelaient jamais l'écriture sur le fichier réel (web, File System
  Access) - les modifications restaient en mémoire et disparaissaient à
  la fermeture de l'onglet. Idem pour la création de catégorie via le
  FAB. Corrigé partout, plus une bannière rouge app-wide si un
  enregistrement échoue pour une autre raison (permission révoquée,
  fichier verrouillé par un autre programme...), avec bouton "Réessayer"
  au lieu d'un échec invisible.

- ~~Verrouillage PIN trop agressif~~ - **fait**. Ne se redéclenche plus au
  simple changement d'onglet/fenêtre (web) - seulement sur un vrai
  rechargement de page ou une mise en arrière-plan réelle (mobile).

- ~~Accents français dans toute l'interface~~ - **fait**. Passe sur
  l'ensemble des chaînes utilisateur (~90 occurrences, une quinzaine de
  fichiers) - identifiants Dart non touchés.

- ~~Petites ergonomies de saisie~~ - **fait**. Sélection de date qui valide
  au clic (plus de bouton OK séparé) ; case "Pointée" dès la création
  d'une transaction ; compte présélectionné sur celui affiché ; montant
  éditable directement dans le grand livre (comme la date), hors
  virements.

- ~~Compteur d'occurrences restantes~~ - **fait**. Les opérations
  récurrentes à durée limitée affichent "(restant/total)" à côté du
  montant (table `APP_BILL_OCCURRENCE_TOTALS`, puisque `NUMOCCURRENCES`
  de MMEX ne garde que le compte restant). Le grand livre affiche aussi
  un badge ↻ avec "n/total" sur les transactions générées depuis une
  récurrence (table `APP_TRANSACTION_BILL_LINKS`) - uniquement pour les
  transactions enregistrées après ce changement, aucun lien rétroactif
  possible sur l'historique.

- ~~Création rapide d'opération récurrente~~ - **fait**. Le bouton "+" du
  grand livre des transactions propose "Nouvelle transaction" ou
  "Nouvelle opération récurrente" sans changer d'onglet.

- ~~En-tête du tableau de bord~~ - **fait**. La prévision est maintenant la
  valeur mise en avant (grande), le solde du jour en dessous en plus
  petit ; toute valeur négative s'affiche en rouge.

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

- ~~Renommer/supprimer une enveloppe de budget~~ - **fait**. Chaque
  enveloppe peut avoir un libellé personnalisé, distinct du nom de la
  catégorie sous-jacente (par défaut, elle suit le nom de la catégorie -
  colonne `NAME` sur `APP_BUDGET_ENVELOPES`). L'édition (nom + montant) et
  la suppression se font directement dans la carte de détail déjà
  affichée en cliquant sur une enveloppe - pas de popup séparée, sur
  demande explicite après plusieurs essais - seule l'enveloppe de la
  catégorie mère est éditable/supprimable depuis là, les sous-catégories
  restent en lecture seule dans la répartition.

- ~~Outil de diagnostic de la base~~ - **fait**. Paramètres > Diagnostic
  de la base : rapport en lecture seule (aucune correction automatique,
  volontairement - vu l'historique du bug de perte de données silencieuse
  ci-dessus) qui liste transactions fantômes/statuts non reconnus,
  références orphelines (catégorie/tiers/compte supprimé sur une
  transaction, une opération récurrente ou une enveloppe de budget),
  catégories mal formées (parent disparu, catégorie sur plus d'un niveau
  d'imbrication - MMEX n'en gère qu'un seul), opérations récurrentes
  épuisées mais toujours présentes, doublons probables (même compte/date/
  montant/tiers) et virements sans destination valide.

## Notes

Cette liste n'est pas priorisée. Pour lancer un chantier, il vaut mieux en
discuter d'abord (portée, maquette rapide si besoin) plutôt que de partir
directement sur l'implémentation - plusieurs demandes précédentes ont
changé de forme une fois qu'on voyait le résultat en pratique.
