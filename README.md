# Money Manager

Application de gestion de budget (web + Android) lisant/ecrivant directement
la base [MoneyManager Ex](https://moneymanagerex.org/) (fichier `.mmb`,
un SQLite standard) — mêmes tables que ton fichier `Bdd/MyMoney.mmb`.

## Mise en route

Flutter doit être installé (SDK Flutter + Android SDK pour l'APK).
Depuis ce dossier :

```bash
flutter create . --platforms=android,web --org com.tondomaine
flutter pub get
flutter run -d chrome      # tester le web
flutter run -d <device-id> # tester sur un telephone/emulateur Android
```

`flutter create .` sur un projet existant ne touche pas à `lib/` ni à
`pubspec.yaml` : il complète juste les dossiers `android/` et `web/`
manquants.

### Build de l'APK

```bash
flutter build apk --release
```

L'APK se trouve ensuite dans `build/app/outputs/flutter-apk/app-release.apk`.

### Build web

```bash
flutter build web --release
```

## Emplacement de la base de données

Au premier lancement, l'app demande de choisir le fichier `.mmb` via le
sélecteur de fichiers natif.

- **Android/desktop** : le fichier est ouvert directement à son emplacement
  (lecture/écriture en place), et le chemin est mémorisé pour les prochains
  lancements. Note : sur Android récent (Storage Access Framework), le
  sélecteur peut renvoyer une copie temporaire du fichier plutôt qu'un accès
  direct selon le fournisseur de stockage (Fichiers locaux, Nextcloud, etc.) —
  si l'accès direct ne marche pas pour votre dossier, dites-le moi, il faudra
  ajouter l'écriture via `ContentResolver`/SAF persistable URI (`shared_storage`
  package) en complément.
- **Web** : les navigateurs ne permettent pas de garder un fichier ouvert en
  continu sur le disque. La base est chargée en mémoire (moteur SQLite en
  WebAssembly) ; pensez à exporter/télécharger régulièrement pour sauvegarder.

### Étape manuelle requise pour le web : `sqlite3.wasm`

Le moteur SQLite compilé en WebAssembly n'est pas embarqué dans ce dépôt.
Après `flutter pub get`, copiez le binaire `sqlite3.wasm` fourni par le
package `sqlite3` dans `web/sqlite3.wasm` (voir la doc du package
[`sqlite3` sur pub.dev](https://pub.dev/packages/sqlite3), section web, pour
la commande exacte selon la version installée).

## Architecture

- `lib/models/` — modèles typés (Account, Category, Payee, MoneyTransaction,
  BudgetEntry...) reflétant les tables `ACCOUNTLIST_V1`, `CATEGORY_V1`,
  `PAYEE_V1`, `CHECKINGACCOUNT_V1`, `BUDGETTABLE_V1`.
- `lib/data/` — accès SQLite cross-platform (`mmex_database_io.dart` en FFI
  natif, `mmex_database_web.dart` en wasm) + `mmex_repository.dart` pour le
  CRUD.
- `lib/state/database_provider.dart` — état global de la base ouverte,
  sélection de fichier, restauration du dernier chemin utilisé.
- `lib/screens/` — Dashboard (bento), Transactions, Comptes, Budget,
  Paramètres.
- `lib/widgets/forecast_chart.dart` — graphique de prévision de solde :
  glisser horizontalement pour explorer le passé (historique réel) ou le
  futur (projection basée sur la moyenne des mois précédents).

## Limitations connues de cette première version

- La projection future est une moyenne glissante simple (pas de saisonnalité
  ni de prise en compte des transactions récurrentes `BILLSDEPOSITS_V1`
  encore planifiées) — amélioration possible ensuite.
- Pas encore d'écran dédié pour gérer catégories/payés/tags indépendamment
  (création à la volée uniquement depuis l'éditeur de transaction).
- Le point `sqlite3.wasm` ci-dessus doit être vérifié/ajusté après
  installation de Flutter, cet environnement ne dispose pas du SDK Flutter
  pour compiler et valider le build web.
