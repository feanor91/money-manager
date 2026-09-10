#!/bin/sh
# Lance le serveur Money Manager et le relance automatiquement s'il
# plante - pas de systemd disponible sur Synology DSM pour un binaire
# tiers, donc supervision "maison" via cette boucle plutôt qu'un vrai
# service (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, décision 3).
#
# À lancer depuis DSM : Panneau de configuration -> Planificateur de
# tâches -> Créer -> Tâche déclenchée -> Au démarrage -> Script défini
# par l'utilisateur -> coller (en remplaçant les valeurs ci-dessous) :
#
#   MM_DB_PATH="/chemin/reel/vers/MesComptes.mmb" \
#   MM_PORT="8899" \
#   MM_DEV_PIN="<choisir un vrai code>" \
#   /volume1/web/mmex-server/start.sh &
#
# Le "&" final est important - sans lui, la tâche planifiée DSM reste
# "en cours d'exécution" indéfiniment et ne redémarre jamais le NAS
# proprement. MM_DB_PATH ne doit JAMAIS pointer vers le vrai fichier
# Nextcloud tant que ce serveur n'a pas été validé en usage réel - une
# copie de test d'abord (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md,
# "Configuration du serveur - deux niveaux distincts").

cd "$(dirname "$0")" || exit 1
export LD_LIBRARY_PATH="$(pwd)"

while true; do
  ./money_manager_server_linux_x64 >> server.log 2>&1
  echo "$(date -Iseconds) - serveur arrêté (code $?), relance dans 3s" >> server.log
  sleep 3
done
