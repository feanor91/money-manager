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
  binaire tiers).

## Étape 1 - Copier ce dossier sur le NAS

Copier tout le contenu de ce dossier vers un nouveau dossier sur
Excelsior, par exemple `/volume1/web/mmex-server/` (à côté de
`web/mmex`, le dossier du site actuel) - le plus simple est de le faire
directement via le partage réseau déjà utilisé pour déployer le site
web.

## Étape 2 - Créer la tâche planifiée (démarrage automatique)

**Pas besoin de toucher aux permissions dans File Station** - l'éditeur
de permissions qui s'y affiche est la vue "ACL" (façon Windows), peu
pratique pour ça. `start.sh` se charge lui-même de rendre l'exécutable
du serveur exécutable (`chmod +x`) à chaque lancement - il suffit de
lancer `start.sh` via l'interpréteur `sh` (`sh start.sh`), qui n'a lui
non plus besoin d'aucun bit d'exécution particulier pour être lu et
exécuté.

Panneau de configuration -> **Planificateur de tâches** -> Créer ->
**Tâche déclenchée** -> **Script défini par l'utilisateur**.

- Déclencheur : **Au démarrage**
- Utilisateur : un compte avec accès en lecture/écriture au dossier
  `mmex-server` ET au fichier `.mmb` réel
- Script (adapter les 3 valeurs) :

```sh
MM_DB_PATH="/chemin/reel/vers/MesComptes.mmb" \
MM_PORT="8899" \
MM_DEV_PIN="choisir un vrai code, pas 1234" \
sh /volume1/web/mmex-server/start.sh &
```

**Important** : `MM_DB_PATH` ne doit JAMAIS pointer vers le vrai fichier
Nextcloud pour l'instant - le serveur n'expose encore qu'une seule route
(`/rpc/getAccounts`), pas de quoi remplacer l'appli réelle. Utiliser une
copie de test d'abord (voir `server/tool/create_dev_db.dart` dans le
repo pour en fabriquer une).

Une fois la tâche créée, la lancer une première fois manuellement (clic
droit -> Exécuter) pour vérifier qu'elle démarre sans attendre un
redémarrage du NAS.

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

- Arrêter : Planificateur de tâches -> la tâche -> Arrêter (ou éteindre
  le NAS/redémarrer, la tâche ne redémarre pas toute seule sans
  redémarrage complet - c'est voulu, pour ne jamais relancer une
  ancienne version après une mise à jour sans s'en rendre compte).
- Mettre à jour : remplacer `money_manager_server_linux_x64` par une
  nouvelle version, puis relancer la tâche planifiée manuellement.
