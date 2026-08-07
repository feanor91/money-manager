# Roadmap

Idées et pistes pour la suite, non planifiées ni engagées - une liste de
courses, pas des engagements.

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
- Ne pas mettre toutes les fonctionnalité dans l'application Andoid, certaines ne sont pas nécessaire (budget, dépnses par catégorie ?...)
- Export csv des différents budgets

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

- ~~Android : "je ne peux pas valider" en saisissant une transaction, +
  reconnaissance du compte à la voix~~ - **fait (2026-08-06)**. Trois
  bugs distincts trouvés en testant en direct avec l'utilisateur :
  1. La fiche transaction restait techniquement tapable pendant sa courte
     animation de fermeture - quelques taps impatients sur "Enregistrer"
     avant qu'elle disparaisse vraiment enregistraient chacun une nouvelle
     transaction (aucun identifiant à mettre à jour pour une nouvelle
     opération, donc chaque appel est un insert). Un verrou `_saving`
     désactive le bouton dès le premier tap.
  2. Plus sérieux : `dashboard_screen.dart` avait sa propre copie de la
     logique d'ouverture de fiche, restée sur `showModalBottomSheet<CategoryChange?>`
     - jamais mise à jour quand `TransactionEditorSheet._save` a commencé
     à retourner un type différent (`TransactionEditorResult`, ajouté avec
     la synchro de montant vers les récurrentes). Aucune erreur à la
     compilation (`Navigator.pop`/`showModalBottomSheet` ne sont reliés
     qu'à l'exécution) : une erreur de cast silencieuse à chaque fermeture,
     qui empêchait `dbProvider.touch()` de s'exécuter - la transaction
     s'enregistrait bien en mémoire (d'où "elle est bien là" à l'écran)
     mais n'atteignait jamais le vrai fichier .mmb. Seulement si le "+" du
     tableau de bord était utilisé (celui de l'onglet Transactions,
     insensible à ce bug, a sa propre copie déjà correcte).
  3. La saisie vocale ne reconnaissait jamais un compte du tout - dire
     "sur le compte Boursorama" ne changeait rien au compte, "Boursorama"
     atterrissait dans Tiers (ou Catégorie) à la place, faute de mieux.
     `parseVoiceTransaction` accepte maintenant la liste des comptes et
     tente une correspondance - uniquement si le mot "compte" est
     prononcé quelque part, pour ne jamais confondre un compte avec un
     tiers du même nom au hasard (exactement ce qui arrivait avant).

  4 nouveaux tests de reconnaissance de compte
  (`test/voice_entry/voice_transaction_parser_test.dart`).
  `flutter analyze`/`flutter test` (285)/`flutter build apk --release`/
  `flutter build web --release` tous vérifiés propres.

- ~~Pause d'une opération du grand livre + synchro montant vers l'opération
  récurrente liée~~ - **fait (2026-08-06)**. Deux demandes distinctes :
  1. Case "En pause" dans la fiche d'une transaction existante - contrairement
     à la pause d'une opération récurrente (qui n'affecte que l'ajout auto/le
     prévisionnel), ici la transaction est réellement exclue du solde et des
     rapports. Réutilise le statut natif "Void" ('V') de MMEX plutôt qu'un
     nouveau filtre applicatif : déjà exclu de *toutes* les requêtes de solde
     de `mmex_repository.dart` (`accountBalance`, `dailyNetTotals`, etc.) sans
     rien y toucher, et compris nativement par le vrai MMEX desktop si le
     fichier y est un jour rouvert. Void partage son unique champ STATUS avec
     "Pointée" (Reconciled) - `APP_PAUSED_TRANSACTIONS` retient si elle était
     pointée juste avant la pause, pour le restaurer correctement à la
     dépause plutôt que de le perdre silencieusement. Ligne grisée (opacité
     55%, même valeur que la pause des opérations récurrentes) + badge dans
     le grand livre (tableau et cartes) ; colonne Statut affiche "V".
  2. Modifier le montant d'une opération provenant d'une récurrente
     (`APP_TRANSACTION_BILL_LINKS`, déjà utilisé pour le badge "généré par
     une récurrente") propose maintenant - **toujours avec confirmation,
     jamais silencieux** - de répercuter le nouveau montant sur le modèle
     récurrent pour les prochaines échéances (`lib/widgets/bill_amount_sync.dart`,
     même schéma que la proposition existante de réaffectation en masse
     d'une catégorie).

  5 nouveaux tests (`test/transaction_pause_test.dart`) : exclusion/retour
  au solde, "Pointée" qui survit à un aller-retour pause/dépause, nettoyage
  du marqueur de pause à la suppression, résolution du lien vers la
  récurrente. `flutter analyze`/`flutter test` (280) propres.

- ~~Champ "Payé" renommé en "Tiers" + saisie vocale dédiée~~ - **fait
  (2026-08-06)**. Ce que le signalement initial ("le 'Payé' n'est pas
  bien pris en compte" en saisie vocale) désignait en fait : le champ
  payee de la fiche transaction/opération récurrente s'appelait "Payé"
  au lieu du terme MoneyManager Ex standard "Tiers" - déjà utilisé
  ailleurs dans le code (`database_diagnostics.dart`). Renommé partout
  (libellé du champ dans `transactions_screen.dart`/`recurring_screen.dart`,
  et le texte de repli "Payé inconnu" -> "Tiers inconnu" dans les 9
  fichiers qui l'affichent). `SearchableSelectField` (le widget partagé
  derrière Tiers *et* Catégorie) gagne un bouton micro optionnel
  (`enableVoiceInput`, Android uniquement) qui dicte directement dans le
  texte de recherche - réutilise le chemin de filtrage existant (donc
  toujours un choix dans la liste filtrée à confirmer, jamais une
  sélection automatique sur la seule foi de la reconnaissance vocale),
  activé pour l'instant seulement sur Tiers dans les deux formulaires
  (pas Catégorie, pas demandé). `flutter analyze`/`flutter test` (275)/
  `flutter build web --release`/`flutter build apk --release` tous
  vérifiés propres.

- ~~Graphique de prévision de solde : le passé n'était plus visible~~ -
  **fait (2026-08-06)**. Régression réelle, confirmée par l'historique
  Git : la toute première version de ce graphique (`c2f44ca`, avant
  l'ajout de la simulation d'achat) était pannable dans le passé (échelle
  jour/semaine/mois, `historyPadding`) ; remplacée depuis par un
  graphique "futur uniquement" qui n'a jamais retrouvé cette capacité.
  `ForecastChart._buildPoints` construit maintenant aussi un segment
  d'historique **réel** (jamais projeté) avant aujourd'hui, sur la même
  durée que celle déjà sélectionnée dans "Durée affichée" (symétrique :
  "1 mois" = 1 mois avant + 1 mois après) - `MmexRepository.dailyNetTotals`
  (l'équivalent réel de `recurringDailyNet`, déjà utilisé pour le futur)
  bucketé par jour en une seule requête, plus `accountBalance(asOf:)` pour
  amorcer le cumul, jamais une requête par jour. L'historique s'affiche en
  trait plein, la projection reste en pointillés (la distinction existait
  déjà via `_Point.projected`, aucun nouveau code de rendu nécessaire).
  Piège évité au passage : la date de départ des mensualités de l'achat
  simulé était calculée à partir de `points.first.day`, qui devient
  maintenant le début de l'historique au lieu d'aujourd'hui - désormais
  ancrée explicitement sur `today`. `flutter analyze`/`flutter test`
  (275) propres.

- ~~État des lieux : mots clé de la saisie vocale (revenu, "Payé")~~ -
  **fait (2026-08-06)**. Liste de mots clé déclenchant un revenu
  (`_incomeKeywords`, `voice_transaction_parser.dart`) : seulement
  "reçu", "salaire", "remboursement", "encaissé", "prime" - "revenu"
  lui-même en était absent, correspondance exacte avec le signalement
  utilisateur. Ajouté (sans ambiguïté possible). "Payé" volontairement
  **pas** ajouté : plus courant au quotidien pour désigner une *dépense*
  ("payé mon loyer", "payé les courses") que pour "j'ai été payé" -
  l'ajouter sans discernement aurait échangé le défaut actuel (mot non
  reconnu, une correction d'un tap) contre un risque pire (dépense
  classée revenu par erreur, silencieusement) ; question renvoyée à
  l'utilisateur plutôt que tranchée à sa place.

- ~~Synchronisation WebDAV intégrée (Android)~~ - **fait, vérifié en
  conditions réelles par l'utilisateur (2026-08-04)** - a trouvé deux
  vrais manques, corrigés le jour même, voir l'entrée "Suite de la
  synchronisation WebDAV" plus bas. Remplace
  Autosync (app tierce payante, qui créait des conflits inexpliqués - dont
  un sur la base elle-même juste avant ce chantier, désactivée par
  l'utilisateur au passage). Nouvelle section `lib/services/webdav/` :
  client HTTP minimal (`webdav_client.dart` - HEAD/GET/PUT contre l'URL
  Nextcloud standard, auth HTTP Basic avec mot de passe d'application, pas
  de PROPFIND/XML) ; logique de décision pure et testée exhaustivement
  (`webdav_sync_decision.dart` - un conflit n'est signalé QUE si le
  téléphone ET le serveur ont changé depuis la dernière synchro connue,
  jamais par simple comparaison d'horodatage) ; identifiants + repère de
  synchro stockés chiffrés et 100% locaux au téléphone
  (`webdav_sync_store.dart`, réutilise `EncryptedFilePreferences` - même
  mécanisme que le hash du code PIN, nouveau fichier dans le dossier de
  support de l'appli, jamais dans le dossier SAF synchronisé) ;
  orchestration (`webdav_sync_service.dart`). `DatabaseProvider` reste le
  seul point d'entrée (comme pour `AndroidFileLink`/`MmexDatabase`
  ailleurs dans ce fichier) : réconciliation automatique et silencieuse au
  lancement (sauf conflit détecté, jamais résolu à l'aveugle), bouton
  "Synchroniser maintenant" dans Paramètres, icône dans le tableau de bord,
  bannière de conflit dans l'appli. La version non choisie lors d'un
  conflit est toujours sauvegardée dans le dossier "backup" existant avant
  d'être écrasée.

  Découverte importante en cours de route : le manifeste Android de
  production n'avait **aucune permission INTERNET** déclarée - elle
  n'avait jamais manqué car tous les appels réseau précédents étaient
  Windows uniquement, mais la vérification de mise à jour Android
  (livrée plus tôt le même jour) faisait déjà de vrais appels HTTP.
  Corrigée au passage - les deux fonctionnalités en dépendaient.

  `flutter analyze`/`flutter test` (223 tests, dont 55 nouveaux pour cette
  fonctionnalité - logique de décision, client HTTP via `MockClient`,
  stockage chiffré, orchestration complète avec un faux serveur)/
  `flutter build apk --release`/`flutter build web --release` tous
  vérifiés propres. Reste à vérifier en conditions réelles sur le vrai
  serveur Nextcloud de l'utilisateur : présence effective d'un en-tête
  ETag, comportement de la toute première synchro contre les vraies
  données, et un vrai scénario de conflit de bout en bout.

- ~~Suite de la synchronisation WebDAV : 3 manques trouvés en conditions
  réelles~~ - **fait (2026-08-04)**. La toute première synchro réelle de
  l'utilisateur a immédiatement révélé ce que la conception n'avait pas
  anticipé :
  1. **"J'ai tapé Résoudre, rien ne s'est affiché"** - en fait le
     comportement prévu (les deux copies se sont révélées identiques une
     fois vraiment comparées, rien à choisir - cas plausible juste après
     avoir désactivé Autosync), mais totalement silencieux : aucun signe
     que quoi que ce soit s'était passé. `handleWebDavSyncTap`
     (`webdav_conflict_dialog.dart`) affiche maintenant un SnackBar dans
     les deux cas (résolution silencieuse vs vrai échec), et un autre
     après une vraie résolution de conflit confirmant la version gardée.
  2. **Un vrai bug** : une modification faite sur desktop restait
     invisible sur Android tant que l'appli n'était pas relancée à froid -
     `restoreLastDatabase()` (seul point d'entrée de la réconciliation
     WebDAV) ne s'exécute qu'une fois par processus, au tout premier
     lancement. Or sur Android, "rouvrir l'appli" veut presque toujours
     dire "revenir depuis le multitâche" (l'OS garde le processus vivant),
     pas un vrai redémarrage - ce cas ne redéclenchait donc jamais la
     vérification. Corrigé en réconciliant aussi sur
     `AppLifecycleState.resumed` (`app.dart`), via le `syncNow()` déjà
     existant du bouton manuel (gère déjà correctement le cas "base
     ouverte en direct").
  3. Demande de l'utilisateur au passage : pousser aussi automatiquement
     les modifications faites sur Android **en quittant** l'appli
     (`AppLifecycleState.paused`), pas seulement au prochain lancement -
     symétrique du point 2. Comme personne ne regarde l'écran à ce
     moment-là, la bannière in-app ne suffit pas : ajout d'une vraie
     notification Android locale (`flutter_local_notifications`, nouvelle
     dépendance - nécessite `POST_NOTIFICATIONS` au manifeste et
     `coreLibraryDesugaringEnabled` côté Gradle, sinon le build release
     échoue à `checkReleaseAarMetadata`) confirmant l'envoi. Best-effort
     assumé : Android peut suspendre le processus peu après `paused`, donc
     un envoi lent n'est pas garanti d'aboutir - net progrès sur "il fallait
     y penser", pas une garantie absolue.

  Les deux déclencheurs automatiques réutilisent `syncNow()` tel quel (déjà
  bidirectionnel : pousse ou tire selon ce qui a réellement changé), donc
  aucune nouvelle logique de décision - seulement de nouveaux points
  d'appel. `flutter analyze`/`flutter test` (223)/`flutter build web
  --release`/`flutter build apk --release` tous vérifiés propres.

- ~~Régression critique : plus aucune base ne s'ouvrait, sur les 3
  plateformes~~ - **fait, confirmé résolu en direct par l'utilisateur
  (2026-08-04)**. Introduite par le correctif du même jour "PIN gate
  substitute screens Navigator/Overlay" (voir plus bas) : `_gated()`
  construisait un nouveau `Navigator` à chaque reconstruction de
  `_PinGate`, mais `Navigator.onGenerateRoute` n'est consulté qu'une seule
  fois, à la création - passer un `child` différent (DbPickerScreen →
  PinUnlockScreen → l'appli réelle) sur les reconstructions suivantes ne
  faisait donc plus rien : Flutter réutilisait le même `NavigatorState`
  sans jamais rafraîchir l'écran affiché. Résultat : l'appli restait
  bloquée sur "Choisir un fichier .mmb" indéfiniment, alors même que
  `DatabaseProvider`/`PinLockProvider` avaient parfaitement fini d'ouvrir
  la base en interne (confirmé par une trace de diagnostic capturée en
  conditions réelles - le fichier s'ouvrait bien, le statut passait à
  `ready`/`locked`, mais l'écran ne bougeait jamais). Le bouton "Créer une
  nouvelle base", resté cliquable sur cet écran fantôme, pouvait alors
  écraser un fichier déjà ouvert avec un schéma déjà initialisé
  (`SqliteException: table ACCOUNTLIST_V1 already exists`) - sans
  toutefois rien corrompre, `CREATE TABLE` échoue proprement sans modifier
  la table existante. Corrigé en donnant à chaque `Navigator` une clé
  dérivée de l'écran affiché (`ValueKey(child.runtimeType)`), pour que
  Flutter le reconstruise réellement (et réinvoque `onGenerateRoute`)
  quand l'écran affiché change vraiment, plutôt que de le réutiliser à
  tort. `flutter analyze`/`flutter test` propres ; vérifié en conditions
  réelles sur desktop par l'utilisateur (base ouverte, code PIN backspace
  fonctionnel) - web et Android partagent le même code corrigé mais
  restent à confirmer séparément.
- ~~Vérification/installation des mises à jour côté Android~~ - **fait,
  confirmé fonctionnel en direct par l'utilisateur (2026-08-04)**. Suite
  du 2026-08-02 (desktop fait ce jour-là). Android a son propre chemin
  maintenant : `checkForUpdatesAndPrompt` (`update_prompt_io.dart`) prend
  en charge Android en plus de Windows, télécharge l'APK depuis la release
  GitHub (`androidApkUrl`, déjà extrait par `update_checker.dart` mais
  jamais branché avant), puis le remet au programme d'installation système
  d'Android - contrairement à desktop, ça ne peut jamais être silencieux,
  Android demande toujours une confirmation de l'utilisateur pour installer
  un APK. Nécessite un peu de code natif Kotlin
  (`MainActivity.kt`) : construire l'URI `content://` à remettre à
  l'installateur passe par `FileProvider.getUriForFile()`, une API
  Java/Kotlin sans équivalent Dart - tout le reste (téléchargement,
  décision si une mise à jour existe) reste en Dart. Ajouts au manifeste :
  permission `REQUEST_INSTALL_PACKAGES` + déclaration `FileProvider` +
  `res/xml/file_paths.xml` exposant le dossier cache de l'appli (là où
  l'APK est téléchargé). `flutter analyze`/`flutter test`/
  `flutter build apk --release` vérifiés propres (aucun conflit de fusion
  du manifeste, aucune erreur Kotlin) ; le vrai scénario "une mise à jour
  existe, taper Installer, confirmer l'installation système" confirmé
  fonctionnel sur un vrai téléphone (2026-08-04).

- ~~Numéro de version invisible sur Android~~ - **fait (2026-08-04)**. Le
  correctif du jour même ("Petits ajustements" plus bas avait ajouté
  l'affichage, mais restait invisible sur Android précisément - voir
  `home_shell.dart`) - passage d'un `Padding` implicite (aligné via le
  `alignment` du `Stack`) à un `Positioned` explicite, par analogie avec
  `_SavingIndicator` déjà correctement positionné - a été vérifié en
  conditions réelles et **ne suffisait pas** : toujours invisible sur un
  vrai téléphone malgré une appli à jour (mise à jour automatique
  confirmée fonctionnelle par ailleurs, voir entrée ci-dessus). Cause
  exacte non déterminée avec certitude (probablement un contraste trop
  faible - texte 9sp à 50% d'opacité sur la barre de navigation - plutôt
  qu'un vrai problème de positionnement). Plutôt que de continuer à
  deviner sans pouvoir tester sur l'appareil réel soi-même, ajout d'un
  second emplacement fiable, à la demande explicite de l'utilisateur
  ("au pire, met le n° de version dans les paramètres") : ligne "Version
  X.X.X" en bas de l'écran Paramètres (`_VersionLabel`, petit
  `StatefulWidget` dédié pour ne lire `PackageInfo.fromPlatform()` qu'une
  fois - `settings_screen.dart` est par ailleurs `Stateless` et se
  reconstruit souvent). L'emplacement d'origine dans la barre de
  navigation est conservé tel quel (fonctionne sur desktop/web).

- ~~3 tests IA locale qui échouaient (pumpAndSettle timeout)~~ - **fait
  (2026-08-04)**. Ces 3 tests de `nl_query_dialog_test.dart` (ceux qui
  tapent "Demander") étaient marqués comme problème connu depuis le
  2026-08-03, cause non trouvée à l'époque. Cause réelle, trouvée avec la
  même méthode d'instrumentation que le bug du PIN ci-dessous :
  `NlQueryDialog._ask()` appelle `AppPreferences.getInstance()` (via
  `isLocalLlmEnabled()`), qui - sans instance déjà en cache - fait un vrai
  accès disque (`File(...).exists()`) pour chercher un marqueur
  `portable.txt` à côté de l'exécutable du test lui-même
  (`flutter_tester.exe`) - un accès disque réel qui ne se termine jamais
  dans l'exécution pilotée par `pumpAndSettle`. Corrigé en pré-remplissant
  le cache d'`AppPreferences` dans `setUpAll` via un nouveau point d'accès
  `debugOverrideInstance`/`debugResetInstance` (réservés aux tests), pour
  que ce chemin de code ne soit jamais atteint. Les 170 tests passent
  maintenant, en ~5 secondes.
- ~~Bug de saisie du code PIN sur desktop/Android~~ - **fait, vérification
  en direct par l'utilisateur en attente (2026-08-04)**. Signalé le
  2026-08-04 : après une erreur de frappe suivie d'un backspace pour
  corriger, retaper faisait réapparaître les chiffres déjà effacés -
  impossible de corriger une erreur une fois commencée. Plusieurs fausses
  pistes explorées d'abord (le masquage web `pinMaskFormatter`, puis
  plusieurs répliques isolées du champ qui ne reproduisaient jamais le
  bug). Cause réelle : `_PinGate` (`app.dart`) affichait l'écran de
  déverrouillage *à la place* du contenu normal de `MaterialApp.builder`
  plutôt qu'imbriqué dedans, donc sans ancêtre `Navigator`/`Overlay`. Dès
  que le champ PIN prenait le focus, Flutter plantait silencieusement dans
  `Overlay.of()` en essayant d'afficher les poignées de sélection de
  texte, laissant l'état interne du champ corrompu - confirmé en
  instrumentant l'écran réel et en capturant sa sortie console (le
  build de test tournait déjà, mais sans base de données configurée,
  donc pas de code PIN à taper avant ça). Corrigé en enveloppant chaque
  écran de substitution dans son propre `Navigator`
  (`_PinGate._gated()`). Au passage, desktop/Android utilisent maintenant
  `obscureText: true` natif plutôt que le masquage personnalisé (qui reste
  la bonne pratique sur web pour éviter l'autofill navigateur, mais
  n'était pas la vraie cause ici).
- ~~Grand livre : afficher tout l'historique plutôt que mois par mois~~ -
  **fait pour desktop et Android, web élargi à 2 mois - vérification en
  direct par l'utilisateur en attente (2026-08-04)**. Signalé le 2026-08-04 :
  la navigation mois par mois (ajoutée le 2026-07-31 pour éviter de
  recalculer le solde courant sur tout l'historique à chaque frappe/
  interaction - voir `getTransactionsWithRunningBalance` dans
  `mmex_repository.dart`) restait gênante pour parcourir le grand livre.
  Desktop **et Android** affichent maintenant tout l'historique du compte
  sélectionné (plus de bornes de date), barre de navigation mois/année
  masquée en conséquence (recherche toujours visible en haut) - viable sur
  les deux car Dart compilé nativement (AOT) + SQLite natif (FFI, via
  `sqlite3_flutter_libs`, qui bundle la même lib native pour Android et
  desktop) rendent ce même calcul quasi instantané, confirmé sur les vraies
  données de l'utilisateur (le plus gros compte ne totalise qu'environ 4 500
  transactions sur 13 ans d'historique). Seul le web reste borné dans le
  temps - même calcul nettement plus coûteux dans un navigateur (Dart
  compilé en JS/Wasm + SQLite compilé en WebAssembly), là où le problème
  d'origine a été observé - mais élargi de 1 à 2 mois (le mois affiché plus
  celui d'avant, fenêtre glissante) plutôt que resté à 1 seul, ce volume
  restant lui aussi négligeable face au seuil qui posait problème.
  `flutter analyze`/`flutter test`/`flutter build windows --release`/
  `flutter build apk --debug` vérifiés propres ; l'écran du grand livre en
  lui-même reste à confirmer en vrai sur desktop, Android et web (voir
  CLAUDE.md - la vérification UI en direct nécessite un vrai fichier .mmb
  ouvert via le sélecteur, pas automatisable depuis cette session).
- ~~Questions en langage naturel ("quelles ont été mes dépenses en
  juillet ?")~~ - **fait, IA locale Windows vérifiée fonctionnelle en
  conditions réelles par l'utilisateur (2026-08-04)**. Nouvelle
  icône bulle de dialogue sur le tableau de bord ("Poser une question"),
  ouvre un dialogue texte libre. Deux moteurs, avec repli automatique du
  second vers le premier :
  - **Analyseur à règles** (`lib/services/nl_query/`) : gratuit, 100%
    local, web/Android/desktop - reconnaît une liste de tournures
    françaises courantes (dépenses/revenus par période, solde d'un compte,
    plus grosses dépenses, dépenses chez un tiers) et les périodes
    correspondantes (mois nommés, "le mois dernier", "cette année", "les N
    derniers mois/jours", plage explicite JJ/MM/AAAA...), résolues contre
    les vraies catégories/comptes/tiers de la base. Le calcul reste
    toujours les mêmes méthodes déterministes de `MmexRepository` - aucun
    risque de chiffre inventé. Entièrement testé (`test/nl_query/`).
  - **IA locale optionnelle (Windows uniquement)** : modèle GGUF (Qwen2.5
    3B ou 7B, au choix) téléchargé à la demande depuis Hugging Face (jamais
    imposé), IA activable/désactivable dans Paramètres. Le modèle ne fait
    jamais que de l'extraction d'intention (quelle catégorie/compte/tiers/
    période est mentionné) vers le même format que l'analyseur à règles -
    jamais de calcul ni de date précise laissés au modèle, jamais de SQL
    généré : la réponse finale passe toujours par le même code
    déterministe.
    **Changement d'approche (2026-08-03)** : abandon de `llama_cpp_dart`
    (FFI) - ni ce paquet ni `llamadart` ne fournissent de binaire Windows
    prêt à l'emploi (`llama_cpp_dart` ne fournit que des bibliothèques
    macOS/iOS précompilées), rendant la compatibilité native jamais
    vérifiable en pratique. Remplacé par un appel HTTP à `llama-server.exe`
    (le serveur officiel du projet llama.cpp, lancé et arrêté par l'appli
    elle-même en sous-processus) - voir
    `lib/services/nl_query/local_llm/llama_server_client.dart` (le client
    HTTP, testé contre un faux serveur local - voir
    `llama_server_client_test.dart`) et `local_llm_manager_io.dart` (cycle
    de vie du process). L'utilisateur doit toujours récupérer manuellement
    la release Windows officielle de llama.cpp (GitHub, un binaire
    réellement prêt à l'emploi cette fois, contrairement aux paquets Dart)
    et placer `llama-server.exe` + ses DLL dans le dossier indiqué par
    l'écran Paramètres - étape documentée dans l'appli, pas automatisée
    (le choix de la variante CPU/CUDA/Vulkan dépend du matériel).
    **Vérifié fonctionnel en conditions réelles (2026-08-04)** : confirmé
    par l'utilisateur sur sa vraie machine Windows avec un vrai
    `llama-server.exe` - démarrage du process, chargement du modèle,
    extraction d'intention fonctionnent bien. `flutter analyze`/
    `flutter test`/`flutter build web`/`flutter build windows` tous
    vérifiés propres.
- ~~Vérification/installation automatique des mises à jour (desktop)~~ -
  **fait, vérification en direct en attente (2026-08-02)**. Au démarrage,
  vérification silencieuse en arrière-plan de la dernière release GitHub
  (`services/update_checker.dart`) ; si une version plus récente existe,
  boîte de dialogue "Version X.X.X disponible, installer ?" avec les notes
  de version, puis téléchargement + lancement de l'installeur Windows et
  fermeture de l'appli (l'installeur prend le relais). Rien ne s'affiche si
  déjà à jour, et un échec de vérification (hors-ligne...) reste
  totalement silencieux plutôt que de gêner le démarrage. Web exclu
  (rien à installer) ; Android en suite séparée (voir Demandées). Logique
  de comparaison de version testée unitairement
  (`test/update_checker_test.dart`) ; `flutter build web`/`flutter build
  windows` vérifiés propres tous les deux (le code touche un import
  conditionnel `dart:io`, comme pour le correctif Android plus tôt le même
  jour) - le vrai scénario "une mise à jour existe, cliquer Installer"
  reste à tester en conditions réelles.
- ~~"Créer une nouvelle base" absent sur le web~~ - **fait**. Signalé le
  2026-08-02 : un nouvel utilisateur web sans fichier `.mmb` existant
  n'avait aucun moyen de commencer (seul "Choisir un fichier .mmb" était
  proposé, "Créer une nouvelle base" était desktop uniquement). Le web a
  maintenant son propre chemin de création (`WebFileLink.
  pickLocationForNewFile`, le sélecteur "enregistrer sous" du navigateur)
  qui construit la même base minimale que sur desktop. Au passage, le
  message d'erreur brut (`NotFoundError: ...`) affiché quand un fichier
  mémorisé est renommé/déplacé est remplacé par un message clair, côté web
  comme desktop.
- ~~Assistant de création de base pour un nouvel utilisateur~~ - **fait,
  vérification en direct par l'utilisateur en attente (2026-08-02)**.
  "Créer une nouvelle base" (desktop) crée toujours une base minimale vide
  (devise EUR, catégories par défaut MMEX) sans rien demander - c'est
  intentionnel et inchangé. Ce qui change : le Tableau de bord distingue
  maintenant "base neuve, zéro compte du tout" de "tous les comptes sont
  masqués" (deux situations qui partageaient le même écran avant, avec le
  mauvais message pour la première) - la base neuve affiche un message de
  bienvenue et un bouton "Créer mon premier compte" (nom, type, solde
  initial - même formulaire que Paramètres > Comptes, extrait en fonction
  partagée `openAccountEditor` plutôt que dupliqué). Fonctionne sur
  n'importe quelle plateforme dès qu'une base a zéro compte, pas seulement
  juste après "Créer une nouvelle base". `flutter analyze`/`flutter test`
  propres ; la vérification bout-en-bout en conditions réelles reste à
  faire par l'utilisateur.
- ~~UI : saisie de transaction depuis le tableau de bord~~ - **fait**.
  Bouton "+" flottant sur le Tableau de bord, même formulaire
  (`TransactionEditorSheet`) et même comportement que celui des
  Transactions - compte présélectionné sur celui affiché.
- ~~UI : icône Budget après Transactions dans la barre du bas~~ - **fait**.
  Ordre désormais Accueil / Transactions / Budget / Récurrentes / Comptes.

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
