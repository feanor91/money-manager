import 'package:flutter/material.dart';

/// One collapsible section of the in-app user guide (see help_screen.dart).
/// [body] is plain French text, paragraphs separated by a blank line and
/// bullet points as "• " lines - rendered as-is in a single Text widget,
/// same convention already used throughout this app's natural-language
/// query answers, so no markdown parser/package is needed for this.
class GuideSection {
  final IconData icon;
  final String title;
  final String body;

  const GuideSection({required this.icon, required this.title, required this.body});
}

/// The full embedded user guide - ships with every build (web/Android/
/// desktop alike, since it's plain Dart source, not a downloaded or
/// separately-deployed asset), shown via Paramètres > Guide d'utilisation.
/// Kept up to date by hand alongside the features it describes; if a
/// feature's behavior changes, update its section here in the same commit.
const userGuideSections = [
  GuideSection(
    icon: Icons.info_outline,
    title: 'Le principe de l\'application',
    body: '''
Money Manager lit et écrit directement le fichier .mmb de MoneyManager Ex (MMEX) - ce n'est pas une copie ou un import : c'est le même fichier, avec les mêmes données, que l'application MMEX classique. Rien n'est stocké ailleurs (pas de compte en ligne, pas de serveur) : tout vit dans ce fichier.

Sur ordinateur, chaque modification est écrite directement sur le disque au fur et à mesure - il n'y a pas de bouton "Enregistrer" séparé.

Sur navigateur web (Chrome/Edge), les modifications sont écrites dans le vrai fichier après un court délai (pour ne pas réécrire tout le fichier à chaque frappe) - un petit indicateur "Sauvegarde…" apparaît en bas de l'écran pendant ce court instant. Si vous fermez l'onglet pendant qu'il est affiché, le navigateur vous avertira que des modifications ne sont peut-être pas encore enregistrées. Sur un navigateur plus ancien qui ne permet pas ce lien direct, la base reste en mémoire pour la session : pensez à "Télécharger une copie" avant de fermer l'onglet.

Ne jamais ouvrir le vrai MMEX de bureau et cette application en même temps sur le même fichier - deux écritures simultanées peuvent corrompre le fichier.''',
  ),
  GuideSection(
    icon: Icons.dashboard_outlined,
    title: 'Tableau de bord',
    body: '''
La page d'accueil : le solde de chaque compte, un graphique de prévision (votre solde futur en tenant compte des opérations déjà prévues et des factures récurrentes), et un aperçu du budget du compte sélectionné.

L'icône 🎨 change la palette de couleurs. L'icône graphique ouvre une analyse des dépenses par catégorie. L'icône bulle ouvre "Poser une question" (voir plus bas). Le bouton "+" ajoute une transaction - sur Android, il propose aussi "Par la voix".''',
  ),
  GuideSection(
    icon: Icons.receipt_long_outlined,
    title: 'Transactions',
    body: '''
Le grand livre de vos opérations. Sur ordinateur et Android, tout l'historique est affiché ; sur le web, seuls les deux derniers mois s'affichent par défaut (pour rester rapide).

Touchez une ligne pour l'ouvrir et la modifier. Dans le tableau (ordinateur/tablette), touchez directement la date ou le montant pour le corriger sans ouvrir toute la fiche.

Le bouton "+" propose : une nouvelle transaction, une nouvelle opération récurrente, et - sur Android - "Par la voix" : dites une phrase, l'application comprend le montant, le tiers, la catégorie (si elle correspond à une catégorie ou un tiers déjà connu) et la date, puis ouvre la fiche habituelle pré-remplie pour que vous vérifiiez avant d'enregistrer - rien n'est jamais enregistré directement depuis la voix. Exemples : "35 euros chez Carrefour hier", "1500 euros de salaire", "20 euros avant-hier".

Par défaut, une phrase dictée est comprise comme une dépense. Pour qu'elle soit comprise comme un revenu, elle doit contenir l'un de ces mots : reçu, salaire, remboursement, encaissé, prime ou revenu. Dates reconnues : "aujourd'hui" (ou rien du tout), "hier", "avant-hier" - toute autre formulation retombe sur aujourd'hui. Le tiers et la catégorie ne sont reconnus que s'ils existent déjà dans vos données (dites leur nom tel quel) ; les virements entre vos propres comptes ne sont pas pris en charge par la voix.

Le champ "Tiers", dans la fiche transaction ou opération récurrente, a aussi son propre bouton micro (Android) : il dicte directement dans la recherche de ce champ, sans passer par toute la phrase - pratique pour ne corriger que ce champ-là.

Un champ de recherche filtre par tiers, catégorie ou montant. Les opérations récurrentes en retard sont proposées automatiquement à l'ouverture de l'application (voir la section Récurrentes).''',
  ),
  GuideSection(
    icon: Icons.pie_chart_outline,
    title: 'Budget',
    body: '''
Deux modes, accessibles par l'icône en haut à droite :

Mode enveloppes (par défaut) : un montant mensuel par catégorie. "Reste à vivre" est votre vrai solde prévisionnel à la date de reset du budget (pas juste "budget moins dépensé") - il tient compte de tout ce qui est déjà prévu sur le compte. Le bouton ✨ suggère automatiquement des enveloppes à partir de votre historique. Une catégorie avec des factures récurrentes actives devient automatique : son montant suit ces factures tant qu'elles existent. Touchez une barre pour voir le détail, renommer l'enveloppe ou voir les opérations derrière.

Mode simulation : des scénarios "et si" nommés, indépendants du vrai budget - jamais modifiés par erreur. Chaque catégorie affiche la moyenne réelle à côté d'un montant simulé modifiable. "Fixer" gèle les montants simulés (ils arrêtent de suivre la moyenne réelle automatiquement) ; "Défixer" les repasse en automatique. Utile pour préparer un budget prévisionnel sans toucher au budget réel.''',
  ),
  GuideSection(
    icon: Icons.autorenew,
    title: 'Opérations récurrentes',
    body: '''
Les factures, salaires ou virements qui reviennent régulièrement. Pour chacune : la fréquence (tous les jours, toutes les semaines, tous les mois, un jour précis du mois, etc.), et comment elle doit être enregistrée :
• Manuelle : vous l'enregistrez vous-même quand elle tombe due.
• Automatique avec confirmation : l'application vous demande, à l'ouverture, si elle doit l'enregistrer.
• Automatique silencieuse : elle est enregistrée sans rien demander (un petit message le confirme).

Une case à cocher permet de mettre une opération en pause (elle est alors ignorée par l'enregistrement automatique et les prévisions). Une durée limitée peut être fixée (ex : un crédit sur 12 mensualités) - la liste affiche alors "3/12".

Supprimer une opération récurrente ne supprime jamais les transactions déjà enregistrées : seul le modèle disparaît.''',
  ),
  GuideSection(
    icon: Icons.account_balance_outlined,
    title: 'Comptes',
    body: '''
Ajouter, modifier, masquer ou supprimer un compte. Masquer un compte (icône œil) le retire des menus et listes sans toucher à son historique ni son solde - entièrement réversible ; c'est l'équivalent pratique de "fermer" un compte que vous n'utilisez plus.

Attention : "Supprimer" efface le compte immédiatement, sans confirmation. Les opérations déjà enregistrées sur ce compte ne sont pas supprimées avec lui (l'écran Diagnostic, plus bas, les signalera comme orphelines).''',
  ),
  GuideSection(
    icon: Icons.category_outlined,
    title: 'Catégories (Paramètres)',
    body: '''
Deux niveaux seulement (catégorie et sous-catégorie, pas plus). Le menu "..." de chaque catégorie propose Renommer, Fusionner, Archiver/Réactiver et Supprimer.

Renommer ou déplacer une catégorie ne touche jamais aux transactions déjà enregistrées avec elle. "Fusionner" déplace tout (transactions, opérations récurrentes, budget) d'une catégorie vers une autre puis supprime la première - uniquement proposé si elle n'a pas de sous-catégorie. Une catégorie encore utilisée ne peut pas être supprimée : l'application explique précisément ce qui l'utilise et propose "Archiver" à la place, qui la cache des listes tout en gardant son historique intact.''',
  ),
  GuideSection(
    icon: Icons.chat_bubble_outline,
    title: 'Poser une question',
    body: '''
Un dialogue pour interroger vos propres finances en français plutôt que de chercher dans les écrans. Fonctionne entièrement hors ligne, sans IA : "Quelles ont été mes dépenses ce mois-ci ?", "Combien j'ai dépensé en Alimentation le mois dernier ?", "Quel est le solde de mon compte ?", "Mes plus grosses dépenses des 3 derniers mois", "Mes dépenses récurrentes le mois dernier", "Mes dépenses en Alimentation par mois depuis le début de l'année", "Pourquoi vais-je finir le mois en négatif ?"

Une question qui ne précise pas de compte porte sur le compte actuellement sélectionné (jamais tous les comptes mélangés en silence). Si la question n'est pas comprise, l'application dit ce qu'elle a quand même reconnu (le compte, la période) pour indiquer que le problème vient précisément du type de question, pas du reste.

Sans IA (donc sur toutes les plateformes), la reconnaissance se fait par mots clés :
• "plus grosses dépenses" ou "top N dépenses" → le classement des plus grosses dépenses
• "pourquoi... négatif/découvert/rouge" ou "vais-je finir... négatif/rouge/découvert" → l'explication d'un solde prévu négatif
• "chez [nom]" → les dépenses chez ce tiers précis
• "solde" ou "balance" → le solde du compte
• dépense, sortie, débit, transaction, opération, achat → une question sur les dépenses ("par mois"/"chaque mois" pour une répartition mois par mois ; "récurrentes" pour ne compter que les opérations liées à une facture récurrente)
• revenu, rentrée, salaire, encaissé, recette, gagné, touché → une question sur les revenus (les deux à la fois comparent revenus et dépenses)

Périodes reconnues : aujourd'hui, hier, cette semaine, la semaine dernière, ce mois, le mois dernier, cette année, l'année dernière, "les 3 derniers mois", "les 15 derniers jours", un nom de mois (avec ou sans année), une année seule (ex. 2025), ou une plage explicite ("du 01/06/2026 au 30/06/2026") - sans précision, c'est le mois en cours. Un compte ou un tiers cité par son nom (ex. "chez Carrefour") filtre la question dessus.

Sur Windows uniquement, une IA locale optionnelle (Paramètres > IA locale) peut comprendre des formulations beaucoup plus libres - elle tourne entièrement sur votre ordinateur, sans connexion internet, et ne calcule jamais elle-même un chiffre : elle choisit seulement ce qu'il faut calculer, le calcul réel est toujours fait par l'application à partir de vos vraies données.''',
  ),
  GuideSection(
    icon: Icons.lock_outline,
    title: 'Code PIN et sécurité',
    body: '''
Paramètres > Code PIN. Un code d'au moins 4 chiffres, demandé à chaque ouverture et à chaque retour au premier plan. Après plusieurs codes erronés (réglable), l'application se verrouille temporairement (durée réglable elle aussi).

Il n'existe aucune récupération en cas de code oublié - si vous le perdez, il n'y a pas de "code oublié". Le code, comme tous les autres réglages, est stocké chiffré à côté du fichier .mmb (voir la section suivante) : il est donc le même sur tous vos appareils qui ouvrent ce fichier.''',
  ),
  GuideSection(
    icon: Icons.sync_outlined,
    title: 'Pourquoi les réglages "suivent" le fichier',
    body: '''
Le code PIN, la palette, le thème, le jour de prévision et les autres réglages ne sont pas stockés sur votre téléphone/ordinateur, mais dans un petit fichier chiffré juste à côté du fichier .mmb. Résultat : ouvrir la même base sur un autre appareil retrouve automatiquement les mêmes réglages, et réinstaller l'application (ou vider les données du navigateur) ne les efface pas tant que le fichier .mmb lui-même est conservé.

Seule exception, forcément propre à chaque appareil : quel fichier ouvrir au démarrage, et les autorisations d'accès (dossier web, dossier Android) - ça ne peut pas être partagé d'un appareil à l'autre par nature.''',
  ),
  GuideSection(
    icon: Icons.cloud_sync_outlined,
    title: 'Synchronisation WebDAV (Android)',
    body: '''
Remplace le besoin d'une application de synchronisation tierce : Paramètres > Synchronisation WebDAV. Il faut l'adresse du serveur (ex : Nextcloud), un identifiant, et un "mot de passe d'application" généré par le serveur (jamais votre vrai mot de passe de compte).

La synchronisation se fait automatiquement à l'ouverture de l'application et quand elle passe au premier/arrière-plan, ou à la demande via "Synchroniser maintenant". En cas de modification des deux côtés depuis la dernière synchronisation, l'application ne devine jamais : elle demande de choisir "Garder ce téléphone" ou "Garder le serveur" (l'autre version est sauvegardée avant, rien n'est perdu).''',
  ),
  GuideSection(
    icon: Icons.fact_check_outlined,
    title: 'Diagnostic de la base',
    body: '''
Un contrôle en lecture seule (rien n'est modifié rien qu'en l'ouvrant) qui recherche : des références vers un compte/catégorie/tiers supprimé, des catégories mal formées, des doublons probables, des virements sans compte de destination. Les résultats sont classés par gravité ; toucher une transaction concernée ouvre directement sa fiche pour la corriger.''',
  ),
];
