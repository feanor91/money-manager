# Plan : passage à une architecture client/serveur avec API

Document de planification - voir ROADMAP.md. Version à jour du 10/09/2026 ;
toutes les décisions structurantes ont été tranchées, le chiffrage fait, et
les étapes 1 à 3 sont **implémentées et réellement déployées** sur Excelsior
(branche `client-serveur`, voir "Statut d'avancement" ci-dessous) -
accessible publiquement à `https://bteuile.ddns.net:8444`.

Une version illustrée de ce document (diagrammes, mise en page) a été
publiée en artifact Claude - celui-ci en est la version texte, gardée dans
le repo pour ne pas la perdre.

## Statut d'avancement (mis à jour au fil du chantier)

- ✅ **Étape 1 - Interface Repository** : `MmexRepository` et les modèles
  extraits dans `packages/money_manager_core/`, paquet Dart pur. `flutter
  analyze`/`flutter test` (609 tests) et `flutter build web --release`
  restent verts, aucun changement de comportement.
- ✅ **Étape 2 - Serveur minimal** : `server/` (shelf + shelf_router),
  une route de preuve de concept (`POST /rpc/getAccounts`), config de
  démarrage par variables d'environnement (`MM_DB_PATH`/`MM_PORT`/
  `MM_DEV_PIN`, jamais de vraie base par défaut). `dart test` (15 tests)
  verts, plus une vérification manuelle réelle : serveur lancé en local
  contre une base de développement jetable, cycle complet login → jeton →
  requête RPC → vraies données, testé en curl et depuis l'appli Flutter
  elle-même (voir étape 3 et `tool/verify_api_client.dart`).
- ✅ **Étape 3 - Authentification serveur** : `PinAuthenticator` (même
  principe que `PinLockProvider` - salt+hash, compteur de tentatives,
  blocage 15 min) et `TokenStore` (jetons Bearer opaques, pas de JWT).
  Un vrai bug trouvé et corrigé en écrivant les tests : le salt du PIN
  était recalculé deux fois différemment dans le constructeur, cassant
  toute vérification - jamais visible sans un test qui appelle réellement
  `verify()`.
- ✅ **Preuve de bout en bout côté client** : `lib/services/api/
  api_client.dart` (client HTTP minimal) et `lib/screens/
  api_debug_screen.dart` (écran de développement, accessible depuis
  Paramètres → "Test API serveur (chantier)", à retirer avant tout
  déploiement réel) - vérifiés contre un vrai serveur réellement lancé,
  via `dart run tool/verify_api_client.dart` (`flutter test` bloque les
  vraies requêtes HTTP par construction, donc pas testable comme un
  widget test classique).
- 🚧 **Étape 4 - Élargir écran par écran** (~12-18 sessions, le plus gros
  morceau) : démarrée - voir le détail plus bas.
- ⏳ **Étapes 5-6** (IA côté serveur, retrait de l'accès fichier direct) :
  pas commencées.
- ✅ **Déploiement réel sur Excelsior** : fait, par l'utilisateur lui-même
  (SSH coupé sur le NAS, pour des raisons de sécurité - déploiement
  entièrement manuel, sans terminal, via l'interface web DSM). Le paquet
  de déploiement (`server/deploy_linux_x64/`, exécutable compilé en
  croisé pour Linux x86_64 via Docker localement, `libsqlite3.so`
  embarquée, `start.sh` avec verrou anti-doublon) a été affiné après
  plusieurs allers-retours réels : bit d'exécution introuvable via
  File Station (corrigé - le script se rend lui-même exécutable),
  déclencheur "au démarrage" absent de cette install DSM (repli sur
  tâche planifiée + répétition horaire, avant que l'utilisateur trouve
  finalement l'option), mauvais nom d'hôte de proxy inversé
  (`mmex.bteuile.synology.me`, un domaine non utilisé - le bon est
  `bteuile.ddns.net`, géré par nginx directement sur le port 8443, donc
  une nouvelle règle DSM sur un port différent - 8444 - ne rentre pas en
  conflit). **Vérifié en conditions réelles, avec les vraies données** :
  requête HTTPS publique depuis internet vers `bteuile.ddns.net:8444`,
  cycle complet login (code PIN réel) -> jeton -> `/rpc/getAccounts` ->
  les 7 vrais comptes de l'utilisateur reçus correctement.

  **Point resté ouvert, accepté pour l'instant par l'utilisateur** : une
  copie de la vraie base (`MesComptes.mmb`) est actuellement placée sous
  `/volume1/web/mmex-server/BDD/` - le dossier que nginx sert
  publiquement (même racine que `web/mmex`, le site déployé). Un test a
  confirmé que ce fichier précis n'est pas servi à cette URL (404), mais
  ça reste un dossier à risque par construction, pas une garantie
  durable - déplacer ce dossier hors de `web/` (ex. `/volume1/mmex-server/`)
  reste recommandé, à faire quand l'utilisateur aura un moment.

- 🚧 **Étape 4 - démarrée** : premier écran réel basculé, en lecture
  seule - **Comptes**, derrière une bascule explicite dans Paramètres
  ("Comptes via API"), jamais activée par défaut. Les deux chemins
  (fichier local / serveur) alimentent le même rendu ; les écritures
  (ajouter/modifier/supprimer un compte) continuent de passer par le
  fichier local même en mode API, conformément à la nuance déjà notée
  plus haut sur la coupure des écritures (jamais progressive comme les
  lectures) - limitation documentée : une modification en mode API ne
  rafraîchit pas automatiquement la vue, un bouton de rafraîchissement
  manuel est fourni à la place.

  2 nouvelles routes serveur (`getBaseCurrency`, `accountBalance`),
  `CurrencyFormat` gagne sa sérialisation JSON. `ApiClient` refactoré
  pour accepter un client HTTP injectable (testable sans réseau réel via
  `package:http/testing.dart`). Nouveau `ApiSessionProvider` : état de
  connexion partagé par toute l'appli, comme `DatabaseProvider`/
  `PinLockProvider`.

  **Sécurité du jeton renforcée** (question posée par l'utilisateur en
  cours de route - "le jeton va être fixe ou renouvelé régulièrement ?
  si fixe et piraté, c'est un problème") : durée de vie par défaut
  réduite de 30 à 7 jours, et nouvelle route `/auth/logout` pour
  révoquer immédiatement un jeton en cas de doute plutôt que d'attendre
  l'expiration naturelle - vérifié que le serveur rejette bien un jeton
  révoqué (401), pas seulement que le client l'oublie en mémoire.

  625 tests au total (dont 16 nouveaux), tous verts. Vérifié en
  conditions réelles contre un vrai serveur lancé en local (toutes les
  routes de cette étape). **Non vérifiable dans cet environnement** : le
  clic-à-clic réel de l'écran dans un navigateur - bloqué par le
  sélecteur de fichier natif (.mmb), même limitation déjà rencontrée
  dans cette session pour d'autres vérifications.

Les 14 écrans restants suivent le même chantier (~12-18 sessions au
total pour l'ensemble) - à démarrer un par un, pas tous d'un coup.

## Où on en est aujourd'hui

L'application ouvre directement le fichier SQLite `.mmb` - sur le disque en
desktop, via l'API File System Access sur le web, via le Storage Access
Framework sur Android. Ce fichier vit dans un dossier Nextcloud, synchronisé
"à l'ancienne" entre les appareils : chaque appareil a sa propre copie
locale, et c'est Nextcloud qui la recopie sur les autres, pas l'application.

Toute la logique d'accès aux données passe par une seule classe,
`MmexRepository` (`lib/data/mmex_repository.dart`) - environ 4500 lignes,
167 méthodes publiques, **toutes synchrones** (aucune n'est `Future`
aujourd'hui, normal pour du SQLite local ouvert en direct). Elle est
construite à un seul endroit réel (`DatabaseProvider`) plus un usage
ponctuel en lecture seule pour l'IA locale. C'est la classe qui porte
pratiquement toute la richesse de l'appli : comptes, transactions, budgets,
récurrences, simulation, et jusqu'au module IA qui écrit et exécute
lui-même des requêtes SQL sur ce fichier.

Le verrouillage par code PIN et les préférences vivent dans un fichier
compagnon chiffré, posé à côté du `.mmb` - voir CLAUDE.md, section "Where
app preferences/settings live".

## Ce que "client/serveur avec API" changerait

Aujourd'hui, chaque application cliente (web/Android/desktop) et le vrai
logiciel MMEX Bureau ouvrent potentiellement le même fichier. Demain, un
seul serveur ouvrirait le fichier ; les applications clientes deviendraient
de purs clients HTTP, parlant à ce serveur en JSON, plus jamais au fichier
directement.

Le serveur serait écrit en **Dart** (paquet léger type `shelf`), pour
pouvoir réutiliser `MmexRepository` quasiment telle quelle côté serveur au
lieu de réécrire toute la logique métier (budgets, récurrences, prévisions)
dans un autre langage - c'est le plus gros raccourci disponible dans ce
projet.

## Les décisions tranchées

**1. Compatibilité avec MMEX Bureau** - le vrai logiciel MMEX doit pouvoir
continuer à ouvrir le fichier directement. -> Le serveur reste bâti sur le
même fichier `.mmb` SQLite (pas de migration vers un autre moteur), et
tourne sur une machine où ce fichier est accessible localement. La règle
actuelle ("jamais MMEX Bureau et l'appli ouverts en même temps sur le même
fichier") s'appliquera entre MMEX Bureau et le serveur, plus simple
qu'aujourd'hui puisque ce sera le seul autre programme à surveiller.

**2. Saisie hors-ligne** - aucune. Pas de file d'attente de transactions à
synchroniser plus tard côté client ; chaque écriture part directement vers
le serveur au moment où elle est faite. Une connexion réseau est requise
pour utiliser l'application. Ça écarte tout le chantier de file d'attente
locale et de réconciliation de conflits.

**3. Où héberger le serveur** - directement sur le NAS "Excelsior" (qui sert
déjà `bteuile.ddns.net:8443` via nginx), à côté de nginx. Pas de Docker
disponible sur ce NAS, mais un accès SSH/shell complet - suffisant pour
faire tourner un exécutable natif Dart (`dart compile exe`, aucune
dépendance à installer). nginx ferait un cran de plus qu'aujourd'hui : en
plus de servir les fichiers statiques, il redirigerait les requêtes API
vers ce processus, sur un port local - même URL publique, un rôle en plus.
Excelsior tourne sous **Synology DSM** (confirmé) - pas de systemd
directement accessible/supporté pour un binaire tiers, donc démarrage au
boot et relance après plantage géreront via le **Task Scheduler** de DSM
(tâche déclenchée au démarrage, exécutant un script qui lance le serveur
et le relance s'il s'arrête) plutôt qu'un vrai service systemd - mécanisme
exact à finaliser à l'étape 2, pas bloquant pour le reste du plan.

**4. Le mode "accès SQL complet" de l'IA** - le module "Poser une question"
tourne entièrement côté serveur. Le client envoie la question en français,
le serveur orchestre l'IA (locale ou cloud) et exécute le SQL généré en
interne, et ne renvoie que la réponse formulée. Aucun SQL ne transite
jamais sur le réseau - important une fois le serveur exposé sur internet
(ce qu'il est déjà via bteuile.ddns.net), alors qu'aujourd'hui ce risque
n'existe pas puisque tout reste local.

### Note technique : SQLite et les procédures stockées

Question posée en cours de route : peut-on déplacer la logique métier dans
des procédures stockées SQLite ? Réponse : non, pas au sens classique -
SQLite est une bibliothèque embarquée, pas un SGBD client/serveur, donc pas
de processus permanent pour héberger du code procédural (pas de `CREATE
PROCEDURE`, pas de boucles/variables comme en PL/pgSQL ou T-SQL). Ce que
SQLite sait faire et qui vit dans le fichier lui-même : des **triggers**
(réactifs, pas de logique appelable à la demande), des **vues** (une
requête nommée, sans logique conditionnelle), et des fonctions
personnalisées - mais définies dans le code de l'application qui ouvre la
base, pas dans le fichier.

Pour la logique visée ici (IA, calculs de budget/récurrences), SQLite ne
pourrait de toute façon pas l'héberger. Bonne nouvelle : le passage au
client/serveur règle déjà le problème réel derrière la question - cette
logique, dupliquée aujourd'hui dans chaque client, n'existera plus qu'à un
seul endroit (`MmexRepository` côté serveur), sans procédures stockées.

Usage ponctuel de triggers envisageable plus tard pour des invariants
simples (ex. garder `APP_BILL_OCCURRENCE_TOTALS` cohérent
automatiquement), mais uniquement sur les tables `APP_` propres à l'appli,
jamais sur les tables MMEX elles-mêmes, par prudence vis-à-vis de MMEX
Bureau.

## Architecture technique retenue pour l'API

- **Framework HTTP** : `shelf` + `shelf_router` (paquets officiels de
  l'équipe Dart) - minimalistes, pas de génération de code, pas de nouvel
  outillage à apprendre. Pas `dart_frog` (routing par fichiers, plus de
  conventions/magie que nécessaire pour une API interne à un seul client).
- **Style d'API : RPC, pas REST classique.** Avec 167 méthodes
  hétérogènes (beaucoup ne sont pas de simples CRUD - calculs de budget,
  projections de récurrences, prévisions de solde), forcer un modèle REST
  "par ressource" serait lui-même un chantier de conception à part
  entière. Convention retenue : une route par méthode,
  `POST /rpc/<nomDeLaMéthode>` avec un corps JSON pour les paramètres,
  résultat JSON en retour - miroir direct des signatures Dart existantes,
  pas de traduction risquée entre deux modèles différents. Quelques routes
  vraiment "ressource" (comptes, transactions, `/auth/login`) peuvent
  rester plus classiques pour la clarté, mais l'essentiel suit cette
  convention uniforme.
- **Sérialisation** : `json_serializable` + `build_runner` pour générer
  `toJson`/`fromJson` sur les 10 classes de `lib/models/` (aucune n'en a
  aujourd'hui) - **révisé après discussion** (2026-09-10) : écrire ces
  méthodes à la main créerait exactement la même classe de bug que "le
  #1 bug récurrent" déjà documenté dans CLAUDE.md ("oublier de
  persister") - un champ ajouté au modèle plus tard, oublié dans un
  `toJson` écrit à la main, silencieusement jamais envoyé au serveur.
  `json_serializable` est aujourd'hui l'approche standard dans
  l'écosystème Flutter pour ce problème précis, et `build_runner` est un
  outil déjà banal (pas un nouvel écosystème à apprendre).
- **Authentification** : middleware `shelf`
  (`Pipeline().addMiddleware(...)`) qui vérifie l'en-tête
  `Authorization: Bearer` sur toutes les routes sauf `/auth/login`.
- **Organisation du code** : paquet Dart pur partagé
  (`packages/money_manager_core/`, voir étape 1 ci-dessous) contenant
  `MmexRepository` et les modèles, utilisé à la fois par l'appli Flutter
  et par le serveur - un seul endroit où vit la logique métier, jamais
  dupliquée entre client et serveur.

### Est-ce que c'est aux standards actuels ? Alternatives écartées

Question posée directement par l'utilisateur (2026-09-10) - réponse
honnête, point par point :

- **`shelf`** : oui, standard - c'est le paquet officiel de l'équipe Dart,
  activement maintenu, et la brique de base sur laquelle des frameworks
  plus haut niveau (comme `dart_frog`) sont eux-mêmes construits. Pas un
  choix daté.
- **Le style RPC (une route par méthode) plutôt que REST** : oui, c'est un
  pattern courant et actuel pour une API interne à un seul client/serveur
  maintenus ensemble - l'équivalent Dart de ce que `tRPC` fait dans
  l'écosystème Node/TypeScript, précisément pour cette situation (pas de
  consommateurs tiers à qui exposer un contrat REST/OpenAPI stable).
- **`json_serializable` plutôt que du `toJson` à la main** : révisé
  ci-dessus - c'est effectivement l'approche la plus standard aujourd'hui
  dans l'écosystème Flutter, pas l'inverse. Bon réflexe de le
  questionner.
- **Alternatives sérieuses écartées, et pourquoi** :
  - **Serverpod** - un framework Dart pensé exactement pour "appli
    Flutter + serveur Dart", avec client typé généré, authentification et
    ORM intégrés. Plus "clé en main" et plus standard sur le papier, mais
    plus de conventions à apprendre et un ORM/schéma propres à Serverpod
    à faire cohabiter avec le schéma SQLite/MMEX existant, pour un projet
    à un seul client - jugé disproportionné ici, mais une alternative
    légitime si le chantier grossit beaucoup.
  - **gRPC/Protobuf** - standard courant en microservices, mais ajoute un
    format binaire (moins facile à inspecter à la main pendant le
    développement qu'un simple JSON via curl/navigateur) et une chaîne de
    génération de code supplémentaire, sans bénéfice clair ici (un seul
    type de client, pas de contrainte multi-langages).
  - **GraphQL** - résout un problème différent (des clients très variés
    qui veulent choisir leurs propres champs sur un schéma partagé) ; pas
    le cas ici avec un seul client Flutter qu'on maîtrise entièrement.

## Sécurité de l'API

**HTTPS** : déjà en place, à réutiliser tel quel. Le nginx d'Excelsior sert
déjà `bteuile.ddns.net:8443` en HTTPS pour le site actuel - c'est lui qui
porterait le certificat TLS pour l'API aussi, redirigeant ensuite en
interne (en clair, sur la machine locale, jamais exposé tel quel) vers le
serveur Dart. Aucun nouveau certificat à gérer.

**Authentification par jeton porteur (Bearer token)** :
1. Le client envoie le code PIN une seule fois, sur `/auth/login` (HTTPS) ;
2. Le serveur le vérifie (même logique de compteur de tentatives/blocage
   qu'aujourd'hui, centralisée côté serveur) et renvoie un jeton ;
3. Chaque requête suivante porte ce jeton dans l'en-tête
   `Authorization: Bearer <jeton>` ;
4. Le jeton a une durée de vie limitée (ex. 30 jours) et reste révocable
   côté serveur à tout moment (ex. appareil perdu).

Deux points à ne pas négliger, précisément parce que le serveur sera exposé
sur internet (ce qui n'est pas le cas du fichier local aujourd'hui) :
- **Limiter le débit des tentatives de connexion** sur `/auth/login` - sans
  ça, un code PIN se force par force brute en quelques minutes depuis
  internet, alors qu'aujourd'hui une attaque équivalente demande un accès
  physique à l'appareil.
- **Où stocker le jeton côté client** - éviter `localStorage` classique sur
  le web (vulnérable en cas de faille XSS), préférer un cookie sécurisé ou
  un stockage en mémoire avec ré-authentification silencieuse ; desktop/
  Android peuvent utiliser le stockage sécurisé du système
  (Keychain/Keystore équivalent).

## Plan de migration par étapes

0. **Cadrage** - fait (ce document).
1. **Extraire une interface `Repository`** - `MmexRepository` reste
   identique, mais passe derrière une interface abstraite, pour permettre
   plus tard une deuxième implémentation (HTTP) sans toucher aux écrans.
   Concrètement : `lib/data/` et `lib/models/` n'importent aucun code
   Flutter (vérifié - seulement `dart:math` et `sqlite3`), donc ils
   peuvent être extraits dans un paquet Dart pur séparé
   (`packages/money_manager_core/`), utilisé à la fois par l'appli Flutter
   (dépendance de chemin) et par le futur serveur - pas de duplication de
   code entre les deux.
2. **Serveur minimal, un seul écran** - petit serveur Dart exposant
   `MmexRepository` derrière quelques routes HTTP, testé sur un écran
   simple (comptes) pour valider le principe de bout en bout.
3. **Authentification serveur** - le code PIN devient une vraie connexion
   serveur (jeton Bearer, voir ci-dessus). Bon moment pour le faire, avant
   d'exposer plus d'écrans.
4. **Élargir écran par écran** - chacune des 167 méthodes de
   `MmexRepository` devient un appel réseau, donc asynchrone (elles sont
   toutes synchrones aujourd'hui) : ajout d'indicateurs de chargement sur
   des écrans qui n'en avaient jamais eu besoin. Le plus gros chantier du
   plan - voir chiffrage ci-dessous pour la nuance sur la bascule des
   écritures.
5. **Déplacer "Poser une question" côté serveur** - le mode IA cloud
   devient un simple appel serveur -> OpenRouter. Le mode IA locale
   (llama.cpp sur la machine de l'utilisateur) garde une architecture
   légèrement différente : le client continue de parler à son propre
   serveur llama.cpp local, mais l'exécution SQL doit passer par un point
   d'entrée serveur *contraint* (jamais de SQL arbitraire accepté depuis le
   réseau) plutôt que par le mode "accès SQL complet" actuel.
6. **Retirer l'accès fichier direct** - une fois tous les écrans basculés
   et vérifiés en usage réel, retrait de tout le code d'ouverture de
   fichier côté client (File System Access, SAF Android, ouverture
   desktop). Point de non-retour, seulement une fois tout validé.

## Chiffrage (ordre de grandeur, en sessions de travail)

Estimation en "sessions" comme celle-ci (un point de travail avec
vérification live avant de passer à la suite), pas en jours-calendaire -
le rythme réel dépend de la disponibilité de l'utilisateur pour tester en
direct à chaque étape, comme pour toutes les fonctionnalités précédentes.

| Étape | Ce qu'elle couvre | Estimation |
|---|---|---|
| 1. Interface Repository | Refactor mécanique d'un seul fichier, faible risque | ~1 session |
| 2. Serveur minimal | Nouveau projet Dart, `shelf`, build/déploiement SSH+nginx+systemd sur Excelsior, un écran de bout en bout | ~2-3 sessions |
| 3. Authentification | Endpoint login, jetons, ré-écriture du flux PIN existant côté serveur, stockage du jeton par plateforme | ~1-2 sessions |
| 4. Élargir écran par écran | 15 écrans, 167 méthodes - inégal selon la complexité (Transactions/Budget/Récurrences/Simulation plus lourds que Tiers/Catégories) | ~12-18 sessions |
| 5. Module IA côté serveur | Cloud simple à déplacer ; IA locale plus délicate (SQL contraint, pas arbitraire) | ~2-3 sessions |
| 6. Retrait de l'accès fichier direct | Suppression de code mort sur 3 plateformes + vérification | ~1 session |
| **Total** | | **~20-28 sessions** |

**Nuance importante sur l'étape 4** : contrairement aux fonctionnalités
précédentes de cette appli (qu'on pouvait activer/tester progressivement
derrière un simple interrupteur), la *lecture* peut basculer écran par
écran sans risque - le serveur et les clients peuvent lire le même fichier
en parallèle sans conflit. Mais l'*écriture*, elle, ne peut pas se
répartir progressivement : à partir du moment où le serveur accepte une
seule écriture, plus aucun client ne doit écrire directement dans le
fichier pour cette donnée, sur aucune plateforme, sous peine de retomber
exactement dans le problème que toute cette migration cherche à éliminer
(deux écrivains sur le même fichier). Ça veut dire une coupure coordonnée
au moment de basculer les écritures - déployer les nouvelles versions de
l'app sur toutes les plateformes utilisées avant d'activer l'écriture côté
serveur -, pas une bascule silencieuse au fil de l'eau.

**Pour réduire le chantier de l'étape 4** si le total ci-dessus semble trop
lourd d'un coup : prioriser les écrans les plus utilisés au quotidien
(tableau de bord, transactions, budget) et laisser les écrans plus rares
(simulation long terme, administration des catégories) en accès fichier
direct plus longtemps - possible tant que ce sont des données *différentes*
qui restent en écriture directe pendant la transition (pas les mêmes
tables touchées des deux façons à la fois).

## Aspects pratiques : configuration et branche de travail

Deux points ajoutés après coup (2026-09-10), avant de commencer quoi que ce
soit concrètement.

### Configuration du serveur - deux niveaux bien distincts

Précision ajoutée après coup (2026-09-10, en réponse à une demande
explicite) : **tout ce qui se règle aujourd'hui depuis l'appli (écran
Paramètres) doit continuer à se régler depuis l'appli**, pas en éditant un
fichier à la main sur le serveur en SSH. Ça sépare la configuration en
deux niveaux, avec une frontière précise :

**Niveau 1 - config de démarrage du serveur (fichier, jamais via l'appli).**
Un minimum de configuration externe au code est nécessaire *avant* que le
serveur puisse répondre à quoi que ce soit d'authentifié - impossible de
la régler depuis l'appli par construction (l'appli ne peut pas parler à un
serveur qui n'a pas encore ces informations pour démarrer). Un fichier de
config (ou des variables d'environnement) **séparé du code et jamais
committé** - exactement le même principe que `android/key.properties`
pour la signature Android (gitignored, présent localement/sur le serveur,
absent sur un checkout neuf) :
- chemin du fichier `.mmb` ;
- port d'écoute ;
- secret de signature des jetons Bearer.
- **Deux profils distincts dès le départ**, jamais mélangés : un profil
  *développement/test* pointant vers une copie jetable de la base (jamais
  le vrai fichier Nextcloud - la base de test bidon utilisée par
  `openBlankTestDb()` dans les tests Flutter, ou une copie de `Bdd/`,
  conviennent très bien) ; et un profil *production*, sur Excelsior,
  pointant vers le vrai chemin. Objectif : pouvoir développer et tester le
  serveur (étapes 1 à 5) sans jamais risquer de toucher `MesComptes.mmb`
  avant que ce soit vraiment voulu et vérifié.

**Niveau 2 - réglages applicatifs (via l'écran Paramètres, comme
aujourd'hui).** Tout le reste - modèle/clé API du fournisseur IA cloud,
`max_tokens`, politique du code PIN (tentatives avant blocage, durée du
blocage, minutes avant auto-verrouillage), etc. - continue de se régler
depuis l'appli exactement comme aujourd'hui. Techniquement, ça veut dire
que l'appli appelle des routes RPC authentifiées du serveur
(`/rpc/getSettings`, `/rpc/setSetting`, ...) au lieu d'écrire dans le
fichier compagnon local - le serveur devient le seul endroit où ces
réglages sont stockés (nouvelles tables `APP_...` dans la base, dans le
même esprit que l'existant), partagés par tous les appareils. C'est la
continuation naturelle de ce qui existe déjà : le fichier compagnon actuel
est *déjà* un seul jeu de réglages partagé par tous les appareils qui
ouvrent le même fichier - ça ne change pas de principe, seulement de
mécanisme (RPC au lieu de lecture/écriture directe du fichier compagnon).
La clé API OpenRouter, en particulier, migre du fichier compagnon local
vers ce stockage de réglages côté serveur - toujours réglable depuis
l'écran Paramètres, jamais éditée à la main sur le serveur.

### Une branche dédiée pour tout le chantier

Ce chantier s'étale sur ~20-28 sessions, probablement plusieurs semaines -
bien plus long que les fonctionnalités habituelles de cette appli, pendant
lesquelles `main` continue de recevoir des correctifs normaux et des
publications de version (le pipeline CI committe lui-même les bumps de
version sur `main`, voir `.github/workflows/release.yml`). Une branche
dédiée (ex. `client-serveur`) évite de mélanger ce chantier en cours avec
les mises en production courantes :

- Créée dès l'étape 1, à partir de `main`.
- Rebasée régulièrement sur `main` au fil du chantier (même réflexe que la
  règle habituelle avant un `push` - `git fetch origin main && git rebase
  origin/main`), pour ne pas trop diverger pendant des semaines.
- Le déploiement vers Excelsior (`flutter build web` + `robocopy`)
  continue de se faire uniquement depuis `main` tant que le chantier n'est
  pas prêt - jamais depuis cette branche.
- Fusion vers `main` seulement quand une étape (ou le chantier entier, à
  décider le moment venu) est stable et vérifiée en usage réel - jamais de
  fusion "à moitié faite".

## Autres points identifiés en creusant le sujet

Quatre points supplémentaires, pas bloquants pour démarrer mais à garder en
tête pendant le chantier :

- **Compatibilité de version client/serveur.** Aujourd'hui, un appareil qui
  n'a pas encore reçu la dernière mise à jour continue simplement de lire
  le fichier local avec l'ancien code - inoffensif. Avec un serveur
  partagé, un client resté sur une ancienne version pourrait appeler une
  route RPC qui a changé de forme entre-temps. Le système de mise à jour
  existant (vérification GitHub Releases au démarrage, voir CLAUDE.md
  "Auto-update") aide déjà beaucoup, mais le serveur devrait quand même
  vérifier un numéro de version envoyé par le client et refuser
  proprement (message clair, pas un plantage) une requête trop ancienne.
- **Sauvegardes côté serveur - tranché (2026-09-10), correction
  importante.** Point corrigé par l'utilisateur : la synchronisation
  Nextcloud n'est **pas** une sauvegarde, c'est une duplication - si
  quelque chose corrompt les données à l'intérieur du fichier, cette
  corruption se retrouve identique sur toutes les copies synchronisées,
  aussi vite que la synchronisation elle-même. Nextcloud ne protège de
  rien ici, il fallait retirer ce point du plan plutôt que le présenter
  comme un "bonus gratuit".

  La vraie réponse existe déjà dans le code actuel, à réutiliser telle
  quelle : `DbBackup`/`db_backup_io.dart`
  (`lib/data/db_backup.dart`/`db_backup_io.dart`) fait exactement ce qu'il
  faut aujourd'hui côté client - une copie horodatée du `.mmb` à chaque
  ouverture/écriture, dans un dossier `backup/` à côté du fichier source,
  avec une purge automatique au-delà d'une rétention glissante
  (`backupRetentionWeeks`, 4 semaines par défaut, réglable). C'est du Dart
  pur (`dart:io` seulement, aucune dépendance Flutter) - directement
  réutilisable côté serveur sans réécriture, appelé après chaque écriture
  exactement comme `DatabaseProvider._backupNow` le fait déjà côté client
  aujourd'hui. Pas un nouveau chantier de conception, juste un
  déplacement de code existant, comme `MmexRepository` elle-même.
- **Journalisation pour du dépannage à distance.** Le serveur tournera sans
  supervision directe (pas comme aujourd'hui où un problème s'observe tout
  de suite dans le navigateur/l'appli ouverte) - prévoir des logs
  consultables par SSH (fichier avec rotation, pas juste la sortie
  standard perdue au redémarrage) pour pouvoir diagnostiquer un souci
  signalé plus tard, sans accès physique à la machine au moment du
  problème.
