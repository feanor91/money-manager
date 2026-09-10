# Déployer le serveur Money Manager sur Excelsior (sans SSH)

Ce dossier contient tout ce qu'il faut - aucune commande SSH nécessaire,
tout se fait depuis l'interface web de DSM. Voir
`PLAN_ARCHITECTURE_CLIENT_SERVEUR.md` dans le repo pour le contexte
complet du chantier.

## Ce qu'il y a dans ce dossier

- `money_manager_server_linux_x64` - l'exécutable du serveur, compilé
  pour Linux x86_64 (vérifié : tourne correctement dans un conteneur
  Debian nu, sans rien installer d'autre - mêmes conditions que DSM).
- `libsqlite3.so` - bibliothèque SQLite nécessaire à l'exécutable (DSM ne
  la fournit pas forcément à l'endroit attendu par défaut) - `start.sh`
  s'assure qu'elle est trouvée sans avoir besoin de l'installer
  ailleurs sur le système.
- `start.sh` - lance le serveur et le relance automatiquement s'il
  plante (pas de vrai service systemd disponible sur ce NAS pour un
  binaire tiers) ; évite de se lancer en double si une instance tourne
  déjà (voir étape 2).

## Étape 1 - Copier ce dossier sur le NAS, HORS du dossier servi par nginx

**Important - ne jamais placer ce dossier (ni la base de données) sous
`/volume1/web/`** : c'est le dossier que nginx sert publiquement (le
même que `web/mmex`, le site déployé) - tout fichier placé dedans peut
devenir accessible depuis internet, y compris un fichier `.mmb` avec de
vraies données financières. Utiliser un dossier séparé, par exemple
**`/volume1/mmex-server/`** (à la racine du volume, pas sous `web/`).

Copier tout le contenu de ce dossier vers ce nouvel emplacement - le
plus simple est de le faire directement via le partage réseau déjà
utilisé pour déployer le site web (mais pas dans le même partage/
dossier que le site lui-même).

## Étape 2 - Créer la tâche planifiée

**Pas besoin de toucher aux permissions dans File Station** - l'éditeur
de permissions qui s'y affiche est la vue "ACL" (façon Windows), peu
pratique pour ça. `start.sh` se charge lui-même de rendre l'exécutable
du serveur exécutable (`chmod +x`) à chaque lancement - il suffit de
lancer `start.sh` via l'interpréteur `sh` (`sh start.sh`), qui n'a lui
non plus besoin d'aucun bit d'exécution particulier pour être lu et
exécuté.

Panneau de configuration -> **Planificateur de tâches** -> Créer ->
**Tâche planifiée** -> **Script défini par l'utilisateur**.

Sur certaines installations DSM, le déclencheur "Au démarrage" (Tâche
déclenchée) n'est pas proposé - dans ce cas, utiliser une tâche
planifiée classique, onglet **Programmer** :

- **Exécuter les jours suivants** -> Répéter : **Quotidienne**
- Cocher **Continuer l'exécution le même jour** -> Répéter :
  **chaque heure**, jusqu'à la dernière heure de la journée

Ça revient à relancer le script toutes les heures, y compris après un
redémarrage du NAS (dans l'heure qui suit) - `start.sh` détecte tout
seul si une instance tourne déjà et ne fait rien dans ce cas (voir le
fichier `server.pid` qu'il crée), donc ces rappels horaires ne créent
jamais de doublon.

Onglet **Paramètres de tâche** :

- Utilisateur : un compte avec accès en lecture/écriture au dossier
  `mmex-server` ET au fichier `.mmb` de test
- Script (adapter les 3 valeurs et le chemin - reprendre l'emplacement
  choisi à l'étape 1) :

```sh
MM_DB_PATH="/volume1/mmex-server/BDD/test.mmb" \
MM_PORT="8899" \
MM_DEV_PIN="choisir un vrai code, pas 1234" \
sh /volume1/mmex-server/start.sh &
```

**Important** : `MM_DB_PATH` ne doit JAMAIS pointer vers le vrai fichier
Nextcloud pour l'instant - le serveur n'expose encore qu'une seule route
(`/rpc/getAccounts`), pas de quoi remplacer l'appli réelle. Utiliser une
copie de test d'abord (voir `server/tool/create_dev_db.dart` dans le
repo pour en fabriquer une vierge).

Une fois la tâche créée, la lancer une première fois manuellement (clic
droit -> Exécuter) pour vérifier qu'elle démarre sans attendre la
prochaine heure pile.

## Étape 3 - Exposer le serveur via nginx (proxy inversé)

Pas besoin d'éditer de fichier de configuration à la main - DSM a son
propre outil graphique pour ça :

Panneau de configuration -> **Portail de connexion** -> **Proxy
inversé** -> Créer.

- Source : le sous-domaine ou chemin souhaité (ex. `bteuile.ddns.net`
  port `8443`, chemin `/api/` - à adapter selon ce qui existe déjà pour
  le site)
- Destination : `127.0.0.1` (ou `localhost`), port `8899` (ou la valeur
  choisie dans `MM_PORT` à l'étape 2)
- HTTPS déjà géré par ce que sert déjà `bteuile.ddns.net:8443` - pas de
  nouveau certificat à créer.

## Vérifier que ça marche

Depuis n'importe quel appareil, une fois les étapes 1 à 3 faites :

```bash
curl -X POST https://bteuile.ddns.net:8443/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"pin":"le code choisi à l'\''étape 2"}'
```

Doit renvoyer `{"token":"..."}`. Sinon, consulter `server.log` dans le
dossier `mmex-server` (créé par `start.sh`) pour voir l'erreur exacte.

## Pour arrêter/mettre à jour le serveur

- **Arrêter maintenant** : Planificateur de tâches -> la tâche -> clic
  droit -> **Arrêter** (ça doit tuer le script en cours, boucle de
  supervision comprise). Désactiver aussi la tâche (case à décocher)
  pour empêcher le prochain rappel horaire de le relancer tout seul -
  les deux sont nécessaires, l'un n'empêche pas l'autre.
- **Mettre à jour** : remplacer `money_manager_server_linux_x64` par
  une nouvelle version, puis arrêter et relancer la tâche manuellement
  (voir ci-dessus) plutôt que d'attendre le prochain rappel horaire.
