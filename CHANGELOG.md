# Changelog

Toutes les modifications notables de ce projet sont consignées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/).

## [1.0.1] - 2026-07-26

### Corrigé
- Les feuilles d'édition (transaction, opération récurrente) ne tenaient
  compte que du clavier pour leur marge basse, pas de la barre de
  navigation système Android - les boutons "Enregistrer"/"Supprimer"
  pouvaient se retrouver à moitié masqués.

## [1.0.0] - 2026-07-25

Première version : lecture/écriture directe d'une base
[MoneyManager Ex](https://moneymanagerex.org/) (`.mmb`, SQLite standard),
en Flutter web + Android.

### Ajouté
- Tableau de bord (style bento) : solde par compte, graphique de prévision
  de solde (glisser pour explorer passé/futur, projection future basée sur
  les transactions récurrentes planifiées), dépenses par catégorie du mois,
  transactions récentes.
- Grand livre des transactions façon MMEX (colonnes Date/Tiers/Statut/
  Catégorie/Débit/Crédit/Solde/Remarques), avec solde courant par ligne,
  édition rapide de la date, pointage, et bascule automatique vers une vue
  en cartes sur petit écran.
- Opérations récurrentes : création/édition (y compris virements), durée
  limitée en nombre d'occurrences, remarque, rattrapage automatique des
  échéances passées à l'ouverture (silencieux ou avec confirmation),
  recherche plein texte et filtre par compte.
- Gestion des comptes : affichage/masquage, réordonnancement par
  glisser-déposer sur le tableau de bord.
- Suivi de budget par catégorie.
- Verrouillage par code PIN (hash salé, jamais stocké en clair),
  ré-activé automatiquement en arrière-plan sur mobile.
- Sauvegardes automatiques horodatées à chaque ouverture de la base
  (dossier `backups/` en natif, dossier `backup/` dans un répertoire
  autorisé par l'utilisateur sur le web).
- Web : lien direct et persistant vers le fichier `.mmb` (File System
  Access API, Chrome/Edge) permettant une écriture immédiate sur disque,
  comme en natif ; repli sur un export manuel pour les autres navigateurs.
- Design responsive (mobile/tablette/desktop) sur l'ensemble des écrans.
