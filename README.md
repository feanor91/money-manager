# Money Manager

Application de gestion de budget (web + Android + desktop Windows) lisant/
écrivant directement une base [MoneyManager Ex](https://moneymanagerex.org/)
(fichier `.mmb`, un SQLite standard) - un vrai fichier MMEX que la version
desktop officielle peut toujours ouvrir, pas un format propriétaire.

## Mise en route

Prérequis : SDK Flutter, et pour l'APK Android un JDK (17 recommandé) +
Android SDK (platform-tools, build-tools, une plateforme récente).

```bash
flutter pub get
flutter run -d chrome      # tester le web
flutter run -d <device-id> # tester sur un telephone/emulateur Android
flutter run -d windows     # tester le desktop
```

Le projet Android est déjà configuré (AGP 8.7 / Gradle 8.10 / Kotlin 2.3.20 -
volontairement fixés à ces versions plutôt qu'aux toutes dernières, pour
rester compatibles avec les plugins actuels comme `file_picker`).

### Build de l'APK

```bash
flutter build apk --release
```

L'APK se trouve ensuite dans `build/app/outputs/flutter-apk/app-release.apk`.
Signé avec un vrai keystore (pas la clé de debug) pour que les mises à jour
s'installent proprement par-dessus une version existante - voir "Signature
Android" plus bas.

### Build web

```bash
flutter build web --release
```

Le contenu de `build/web` est un site statique, déployable sur n'importe
quel serveur web (voir "Déploiement" plus bas pour les points d'attention).

### Build desktop Windows

```bash
flutter build windows --release
```

## Fonctionnalités principales

- **Tableau de bord** : soldes par compte, prévision de solde glissable
  (passé réel + projection future basée sur les opérations récurrentes),
  accès rapide aux autres écrans.
- **Grand livre (Transactions)** : vue tableau (desktop/large écran, tri et
  colonnes personnalisables) ou cartes (mobile), recherche, saisie vocale
  (Android), duplication d'une opération, suppression avec "Annuler".
- **Opérations récurrentes** : liste des échéances planifiées (MMEX
  `BILLSDEPOSITS_V1`), mise en pause sans suppression, duplication,
  répartition d'une échéance en plusieurs versements, et **augmentation
  annuelle** par opération (pourcentage suggéré à partir de l'historique
  réel des transactions, appliqué composé à la date anniversaire dans les
  projections - jamais dans les vraies opérations enregistrées).
- **Budget** : suivi par catégorie avec enveloppes, mode simulation sur
  plusieurs mois.
- **Simulation long terme** : scénarios "et si" multi-comptes sur plusieurs
  années - désactiver/modifier une opération récurrente réelle, en ajouter
  une virtuelle, ajouter un événement ponctuel, comparer plusieurs scénarios
  sauvegardés. Calcul 100% déterministe (jamais délégué à l'IA).
- **Explorateur de dépenses** : répartition par catégorie/compte sur une
  période, filtrable.
- **Comptes, catégories, tiers** : écrans de gestion dédiés (au-delà de la
  simple création à la volée depuis l'éditeur de transaction).
- **"Poser une question"** (langage naturel) : un analyseur à règles
  100% local et gratuit répond aux questions courantes (dépenses/revenus
  par période, solde, plus grosses dépenses...) en calculant toujours via
  les mêmes méthodes déterministes du dépôt de données - jamais de chiffre
  inventé par un modèle. Deux IA optionnelles peuvent prendre le relais
  pour des questions plus libres ou un accès SQL complet en lecture seule
  (jamais d'écriture) :
  - **IA locale** (desktop : modèle GGUF téléchargé et exécuté sur la
    machine ; web : le navigateur parle à un serveur `llama.cpp` que
    l'utilisateur fait tourner lui-même sur son PC).
  - **IA cloud** (endpoint compatible OpenAI, ex. OpenRouter) - clé API
    fournie par l'utilisateur dans les Paramètres.
- **Synchronisation WebDAV (Android)** : synchro automatique et
  bidirectionnelle avec un serveur Nextcloud, détection de conflit réelle
  (pas une simple comparaison d'horodatage), notification locale à
  l'envoi en arrière-plan.
- **Mise à jour automatique** (desktop + Android) : vérifie les releases
  GitHub au démarrage, télécharge et installe (silencieusement sur
  desktop, avec confirmation système sur Android).
- **Verrouillage par code PIN**, **sauvegardes automatiques horodatées**
  à chaque ouverture, **thème/palette personnalisables**.

## Emplacement de la base de données

Au premier lancement, l'app demande de choisir le fichier `.mmb` via le
sélecteur de fichiers natif.

- **Desktop** : le fichier est ouvert directement à son emplacement
  (lecture/écriture en place), et le chemin est mémorisé pour les prochains
  lancements.
- **Android** : passe par le Storage Access Framework (SAF) - on choisit un
  **dossier** (pas juste un fichier), l'app y trouve le `.mmb`/`.db`/
  `.sqlite` à l'intérieur. **Ne jamais choisir l'entrée "Nextcloud" du
  sélecteur de dossier système** - la lecture plante avec
  `NetworkOnMainThreadException` (bug connu et non résolu du côté de
  l'app Android Nextcloud elle-même, pas de ce projet). À la place,
  synchroniser le dossier via une app tierce en WebDAV vers un dossier
  local réel (voir `lib/data/android_file_link_io.dart` pour le détail
  technique), puis choisir ce dossier local.
- **Web (Chrome/Edge)** : via la File System Access API, le fichier choisi
  reste lié en continu - chaque modification est écrite directement dans le
  vrai fichier sur disque, comme en natif. L'accès est mémorisé d'une session
  à l'autre (juste une reconfirmation de permission au démarrage). Ceci
  nécessite un **contexte sécurisé** (`https://` ou `localhost` - voir
  "Déploiement").
- **Web (autres navigateurs, ou HTTP sans certificat)** : repli sur une
  lecture ponctuelle en mémoire. Les modifications ne sont pas réécrites sur
  disque automatiquement ; pensez à "Télécharger une copie .mmb" depuis les
  Paramètres avant de fermer l'onglet.

### `sqlite3.wasm`

Le moteur SQLite compilé en WebAssembly, requis pour la version web, est
commité directement dans ce dépôt (`web/sqlite3.wasm`) plutôt que copié
manuellement à chaque poste - une étape manuelle avait déjà causé une
régression en production (le fichier supprimé par erreur lors d'un
déploiement à la main) qu'un fichier absent du dépôt ne peut plus provoquer.
Si le package `sqlite3` est mis à jour vers une version dont le binaire WASM
diffère, remplacez ce fichier par la nouvelle version fournie par le package
(voir sa doc sur [pub.dev](https://pub.dev/packages/sqlite3), section web)
et commitez-le.

## Sauvegardes automatiques

À chaque ouverture réussie de la base, une copie horodatée est enregistrée
avant toute modification de la session (voir `lib/data/db_backup*.dart`) :

- **Android/desktop** : écrite dans un dossier `backups/` créé à côté du
  fichier `.mmb` d'origine.
- **Web (Chrome/Edge)** : au moment de choisir le fichier, une seconde
  fenêtre demande l'autorisation d'accéder au dossier qui le contient - une
  seule fois. Ensuite, la sauvegarde est automatique et silencieuse dans un
  sous-dossier `backup/` de ce dossier. Nécessite le même contexte sécurisé
  que le lien direct ci-dessus ; sans lui, aucune sauvegarde automatique
  n'est possible sur le web (le fichier ne peut alors être exporté qu'à la
  main).

## Réglages : où ils sont stockés

- **La plupart des préférences** (code PIN - hash salé uniquement, jamais en
  clair -, palette, thème, jour de prévision, compte sélectionné, comptes
  masqués, ordre d'affichage, colonnes du grand livre...) vivent dans un
  fichier compagnon **chiffré** (`money_manager_settings.dat`) situé **dans
  le même dossier que le `.mmb` ouvert** - donc synchronisé avec lui (dossier
  Nextcloud, par exemple) et partagé entre tous les appareils qui ouvrent ce
  fichier. Un code PIN défini sur un appareil s'applique donc sur tous les
  autres ouvrant la même base - ce n'est volontairement plus un réglage par
  appareil.
- **Seuls les réglages qui ne peuvent techniquement pas être partagés**
  restent locaux à l'appareil/navigateur (`AppPreferences`) : quelle base
  rouvrir au démarrage, les permissions de fichier/dossier déjà accordées
  par ce navigateur, l'URI SAF mémorisée sur Android, les identifiants
  WebDAV (chiffrés, jamais dans le dossier synchronisé).

C'est une protection applicative simple contre un accès opportuniste
(téléphone déverrouillé égaré, URL devinée) - pas un chiffrement du fichier
`.mmb` lui-même, qui reste lisible par quiconque y a accès directement
(disque, partage réseau, etc.).

## Signature Android

L'APK de release est signé avec un vrai keystore stable (pas la clé de
debug), pour que les mises à jour s'installent en place plutôt que d'exiger
une désinstallation à chaque nouvelle version. En CI, les secrets du dépôt
fournissent le keystore ; en local, `android/key.properties` (gitignored)
pointe vers une copie du même keystore - absent sur un checkout tout neuf,
l'app se rebâtit alors avec la clé de debug (fonctionne, mais ne pourra pas
mettre à jour une installation déjà signée avec le vrai keystore).

## Déploiement (auto-hébergement de la version web)

La version web est un site statique classique (Nginx, Apache, Web Station
Synology...). Deux points d'attention :

- Servir `sqlite3.wasm` avec le type MIME `application/wasm` (généralement
  déjà correct sur les serveurs récents - à vérifier si le chargement de la
  base échoue silencieusement).
- Utiliser **HTTPS** (même avec un certificat auto-signé accepté une fois
  par navigateur) pour bénéficier du lien direct et des sauvegardes
  automatiques - la File System Access API est indisponible en HTTP simple.

Aucune authentification n'est intégrée au niveau du serveur : si le site est
exposé sur internet, prévoir une protection en amont (contrôle d'accès du
reverse proxy, authentification HTTP, VPN...) en complément du code PIN
applicatif.

Après un déploiement, un simple rechargement de page peut encore afficher
l'ancienne version tant que le navigateur garde `main.dart.js` en cache -
recharger avec un paramètre d'URL jetable (`?x=1`) ou un vrai
rechargement forcé force une vraie requête.

## Architecture

- `lib/models/` - modèles typés (Account, Category, Payee, MoneyTransaction,
  BillDeposit, BudgetEntry, SimScenario...) reflétant les tables MMEX
  (`ACCOUNTLIST_V1`, `CATEGORY_V1`, `PAYEE_V1`, `CHECKINGACCOUNT_V1`,
  `BILLSDEPOSITS_V1`, `BUDGETTABLE_V1`...) et les tables propres à l'app
  (préfixées `APP_`, voir ci-dessous).
- `lib/data/` - accès SQLite cross-platform (`mmex_database_io.dart` en FFI
  natif, `mmex_database_web.dart` en wasm) + `mmex_repository.dart` pour le
  CRUD (le plus gros fichier du projet) ; `web_file_link*.dart`/
  `android_file_link*.dart` pour le lien direct au fichier (File System
  Access API sur web, SAF sur Android) ; `db_backup*.dart` pour les
  sauvegardes automatiques ; `db_companion_settings.dart` pour le fichier de
  réglages compagnon.
- `lib/services/webdav/` - client HTTP minimal, logique de décision de
  synchro/conflit (testée exhaustivement), orchestration.
- `lib/services/nl_query/` - analyseur à règles pour "Poser une question",
  plus `local_llm/` (IA locale et cloud : extraction d'intention, moteur SQL
  en lecture seule validé, clients HTTP).
- `lib/services/voice_entry/` - reconnaissance vocale d'une transaction.
- `lib/services/update_checker.dart` - vérification de nouvelle version
  contre les releases GitHub.
- `lib/state/database_provider.dart` - état global de la base ouverte,
  sélection de fichier, restauration du dernier fichier utilisé, écriture
  différée (`touch()`) vers le fichier réel.
- `lib/state/pin_lock_provider.dart` - état du verrouillage par code PIN.
- `lib/screens/` - Tableau de bord, Transactions, Récurrentes, Budget,
  Simulation, Explorateur de dépenses, Comptes, Catégories, Tiers,
  Paramètres, Aide.
- `lib/widgets/` - composants partagés (éditeur de transaction, graphique de
  prévision, sélecteurs, dialogues de question IA...).

## Tables applicatives (`APP_*`)

Au-delà des tables MMEX standard (traitées en lecture/écriture mais jamais
restructurées), l'app ajoute ses propres tables préfixées `APP_` pour du
stockage que le schéma MMEX ne prévoit pas (pause d'une opération, liens
transaction↔récurrente, enveloppes de budget, augmentation annuelle,
scénarios de simulation...). Créées via
`MmexRepository.ensureAppSchema()`, appelée à chaque ouverture de base -
sans danger pour un fichier ouvert par la vraie appli MMEX desktop, qui les
ignore simplement.

## Limitations connues

- La projection future du tableau de bord ne tient compte que des
  opérations récurrentes connues (`BILLSDEPOSITS_V1`, avec augmentation
  annuelle optionnelle) - pas des dépenses discrétionnaires habituelles. La
  Simulation long terme permet d'ajouter manuellement ce genre d'hypothèses
  scénario par scénario.
- Le code PIN est une protection applicative simple, pas un chiffrement des
  données (voir "Réglages" ci-dessus).
- Aucune authentification serveur intégrée pour un déploiement web exposé
  sur internet (voir "Déploiement" ci-dessus).
- Toute l'interface est en français en dur dans le code - pas de
  localisation multilingue prévue tant qu'il n'y a qu'un utilisateur
  francophone (voir ROADMAP.md).
- La synchronisation WebDAV ne parle qu'au protocole WebDAV de Nextcloud
  (URL construite en dur sur sa structure) - pas de Google Drive/Dropbox.
