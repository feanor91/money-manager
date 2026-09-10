#!/bin/sh
# Lance le serveur Money Manager et le relance automatiquement s'il
# plante - pas de systemd disponible sur Synology DSM pour un binaire
# tiers, donc supervision "maison" via cette boucle plutôt qu'un vrai
# service (voir PLAN_ARCHITECTURE_CLIENT_SERVEUR.md, décision 3).
#
# Se rend lui-même exécutable (chmod +x) au démarrage, y compris pour
# l'exécutable du serveur lui-même - un fichier copié depuis un partage
# réseau Windows n'a en général aucun bit d'exécution Unix, et l'éditeur
# de permissions "ACL" de File Station est peu pratique pour ça (voir
# LISEZMOI_DEPLOIEMENT.md). Cette ligne veut dire que start.sh n'a même
# pas besoin d'être exécutable lui-même : il suffit de le lancer via
# `sh start.sh` (voir l'étape 2 du guide).
#
# Pas de déclencheur "Au démarrage" disponible sur toutes les versions/
# installations de DSM (signalé par l'utilisateur - absent du menu créé)
# - à la place, une "Tâche planifiée" classique en répétition horaire
# (voir l'étape 2 du guide) rappelle ce script toutes les heures, y
# compris après un redémarrage du NAS. D'où le verrou ci-dessous : sans
# lui, chaque rappel horaire lancerait une deuxième boucle de
# supervision en plus de celle déjà en cours, avec un deuxième processus
# qui échouerait juste à se lier au port déjà pris - inoffensif mais
# confus dans les journaux, ce verrou l'évite proprement.

cd "$(dirname "$0")" || exit 1

PIDFILE="server.pid"
if [ -f "$PIDFILE" ]; then
  OLDPID="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    # Une instance tourne déjà (rappel horaire alors que le serveur de
    # l'heure précédente tourne toujours) - rien à faire.
    exit 0
  fi
fi
echo $$ > "$PIDFILE"

chmod +x ./money_manager_server_linux_x64 2>/dev/null
export LD_LIBRARY_PATH="$(pwd)"

while true; do
  ./money_manager_server_linux_x64 >> server.log 2>&1
  echo "$(date -Iseconds) - serveur arrêté (code $?), relance dans 3s" >> server.log
  sleep 3
done
