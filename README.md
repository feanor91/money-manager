# Money Manager

Application de gestion de budget (web + Android) lisant/ecrivant directement
la base [MoneyManager Ex](https://moneymanagerex.org/) (fichier `.mmb`,
un SQLite standard) — mêmes tables que ton fichier `Bdd/MyMoney.mmb`.

## Mise en route

Prérequis : SDK Flutter, et pour l'APK Android un JDK (17 recommandé) +
Android SDK (platform-tools, build-tools, une plateforme récente).

```bash
flutter pub get
flutter run -d chrome      # tester le web
flutter run -d <device-id> # tester sur un telephone/emulateur Android
```

Le projet Android est déjà configuré (AGP 8.7 / Gradle 8.10 / Kotlin 2.0.20 —
volontairement fixés à ces versions plutôt qu'aux toutes dernières, pour
rester compatibles avec les plugins actuels comme `file_picker`).

### Build de l'APK

```bash
flutter build apk --release
```

L'APK se trouve ensuite dans `build/app/outputs/flutter-apk/app-release.apk`.

### Build web

```bash
flutter build web --release
```

Le contenu de `build/web` est un site statique, déployable sur n'importe
quel serveur web (voir "Déploiement" plus bas pour les points d'attention).

## Emplacement de la base de données

Au premier lancement, l'app demande de choisir le fichier `.mmb` via le
sélecteur de fichiers natif.

- **Android/desktop** : le fichier est ouvert directement à son emplacement
  (lecture/écriture en place), et le chemin est mémorisé pour les prochains
  lancements. Note : sur Android récent (Storage Access Framework), le
  sélecteur peut renvoyer une copie temporaire du fichier plutôt qu'un accès
  direct selon le fournisseur de stockage (Fichiers locaux, Nextcloud, etc.) —
  non vérifié en conditions réelles pour l'instant ; si l'accès direct ne
  marche pas pour votre dossier, il faudra ajouter l'écriture via
  `ContentResolver`/SAF persistable URI (`shared_storage` package).
- **Web (Chrome/Edge)** : via la File System Access API, le fichier choisi
  reste lié en continu — chaque modification est écrite directement dans le
  vrai fichier sur disque, comme en natif. L'accès est mémorisé d'une session
  à l'autre (juste une reconfirmation de permission au démarrage). Ceci
  nécessite un **contexte sécurisé** (`https://` ou `localhost` — voir
  "Déploiement").
- **Web (autres navigateurs, ou HTTP sans certificat)** : repli sur une
  lecture ponctuelle en mémoire. Les modifications ne sont pas réécrites sur
  disque automatiquement ; pensez à "Télécharger une copie .mmb" depuis les
  Paramètres avant de fermer l'onglet.

### Étape manuelle requise pour le web : `sqlite3.wasm`

Le moteur SQLite compilé en WebAssembly n'est pas embarqué dans ce dépôt.
Après `flutter pub get`, copiez le binaire `sqlite3.wasm` fourni par le
package `sqlite3` dans `web/sqlite3.wasm` (voir la doc du package
[`sqlite3` sur pub.dev](https://pub.dev/packages/sqlite3), section web, pour
la commande exacte selon la version installée).

## Sauvegardes automatiques

À chaque ouverture réussie de la base, une copie horodatée est enregistrée
avant toute modification de la session (voir `lib/data/db_backup*.dart`) :

- **Android/desktop** : écrite dans un dossier `backups/` créé à côté du
  fichier `.mmb` d'origine.
- **Web (Chrome/Edge)** : au moment de choisir le fichier, une seconde
  fenêtre demande l'autorisation d'accéder au dossier qui le contient — une
  seule fois. Ensuite, la sauvegarde est automatique et silencieuse dans un
  sous-dossier `backup/` de ce dossier. Nécessite le même contexte sécurisé
  que le lien direct ci-dessus ; sans lui, aucune sauvegarde automatique
  n'est possible sur le web (le fichier ne peut alors être exporté qu'à la
  main).

## Verrouillage par code PIN

Un code PIN optionnel (Paramètres > Code PIN) peut être défini pour exiger
sa saisie à chaque ouverture de l'appli, et de nouveau après une mise en
arrière-plan sur mobile (`lib/state/pin_lock_provider.dart`). Seul un hash
salé est stocké, jamais le code en clair. C'est une protection applicative
simple contre un accès opportuniste (téléphone déverrouillé égaré, URL
devinée) — pas un chiffrement des données : le fichier `.mmb` lui-même reste
lisible par quiconque y a accès directement (disque, partage réseau, etc.).
Ce réglage est local à chaque appareil/navigateur, à définir séparément sur
chacun.

## Déploiement (auto-hébergement de la version web)

La version web est un site statique classique (Nginx, Apache, Web Station
Synology...). Deux points d'attention :

- Servir `sqlite3.wasm` avec le type MIME `application/wasm` (généralement
  déjà correct sur les serveurs récents — à vérifier si le chargement de la
  base échoue silencieusement).
- Utiliser **HTTPS** (même avec un certificat auto-signé accepté une fois
  par navigateur) pour bénéficier du lien direct et des sauvegardes
  automatiques - la File System Access API est indisponible en HTTP simple.

Aucune authentification n'est intégrée au niveau du serveur : si le site est
exposé sur internet, prévoir une protection en amont (contrôle d'accès du
reverse proxy, authentification HTTP, VPN...) en complément du code PIN
applicatif.

## Architecture

- `lib/models/` — modèles typés (Account, Category, Payee, MoneyTransaction,
  BillDeposit, BudgetEntry...) reflétant les tables `ACCOUNTLIST_V1`,
  `CATEGORY_V1`, `PAYEE_V1`, `CHECKINGACCOUNT_V1`, `BILLSDEPOSITS_V1`,
  `BUDGETTABLE_V1`.
- `lib/data/` — accès SQLite cross-platform (`mmex_database_io.dart` en FFI
  natif, `mmex_database_web.dart` en wasm) + `mmex_repository.dart` pour le
  CRUD ; `web_file_link*.dart` pour le lien direct au fichier sur web (File
  System Access API) ; `db_backup*.dart` pour les sauvegardes automatiques.
- `lib/state/database_provider.dart` — état global de la base ouverte,
  sélection de fichier, restauration du dernier fichier utilisé.
- `lib/state/pin_lock_provider.dart` — état du verrouillage par code PIN.
- `lib/screens/` — Dashboard (bento), Transactions (grand livre façon MMEX,
  version cartes sur petit écran), Récurrentes (avec recherche/filtre par
  compte), Comptes, Budget, Paramètres.
- `lib/widgets/forecast_chart.dart` — graphique de prévision de solde :
  glisser horizontalement pour explorer le passé (solde réel reconstruit
  depuis le grand livre) ou le futur (projection basée uniquement sur les
  transactions récurrentes `BILLSDEPOSITS_V1` déjà planifiées - pas de
  moyenne ni d'estimation des dépenses discrétionnaires pour l'instant).
- `lib/widgets/responsive_body.dart` — centre et limite la largeur du
  contenu sur grand écran, utilisé par la plupart des écrans.

## Limitations connues de cette première version

- La projection future ne tient compte que des opérations récurrentes
  connues (`BILLSDEPOSITS_V1`) - pas des dépenses discrétionnaires
  habituelles ni du budget défini par catégorie. Amélioration possible
  ensuite en y intégrant le budget une fois celui-ci jugé fiable.
- Pas encore d'écran dédié pour gérer catégories/payés/tags indépendamment
  (création à la volée uniquement depuis l'éditeur de transaction).
- Le code PIN est une protection applicative simple, pas un chiffrement des
  données (voir "Verrouillage par code PIN" ci-dessus).
- Aucune authentification serveur intégrée pour un déploiement web exposé
  sur internet (voir "Déploiement" ci-dessus).
