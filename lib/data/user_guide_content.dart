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

Une case à cocher permet de mettre une opération en pause (elle est alors ignorée par l'enregistrement automatique et les prévisions, et reléguée en bas de la liste). Une durée limitée peut être fixée (ex : un crédit sur 12 mensualités) - la liste affiche alors "3/12". Le bouton "Dupliquer" repart d'une opération existante sans tout ressaisir - tout est recopié (montant, compte, catégorie, fréquence...), à l'inverse d'une transaction dupliquée dans le grand livre qui, elle, vide le montant et repart d'aujourd'hui.

Au moment d'enregistrer une occurrence d'une opération dont la périodicité couvre plusieurs mois (trimestrielle, semestrielle, annuelle...), un menu "Répartir en X fois" permet de l'étaler en plusieurs échéances mensuelles égales (à un centime près) à partir de la date d'échéance - pratique pour lisser une grosse facture sur la trésorerie (ex. régler une prime d'assurance trimestrielle en 3 fois) sans jamais toucher au calendrier réel de l'opération : la prochaine échéance reste à la même date qu'avant, seul le paiement de celle-ci a été fractionné. Le nombre maximal de fois proposé correspond à la durée de la période (jusqu'à 3 fois pour une opération trimestrielle, 6 pour une semestrielle, etc.).

L'icône 📈 ouvre "Augmentation annuelle" : un pourcentage qui compose chaque année, à la date anniversaire choisie, le montant utilisé dans les projections (Simulation, prévision de solde) - jamais le montant réel de l'opération elle-même. L'application suggère une valeur à partir de l'historique réel de cette opération précise (minimum 3 ans de recul), mais rien n'est jamais appliqué automatiquement : la suggestion doit être acceptée puis enregistrée.

Supprimer une opération récurrente ne supprime jamais les transactions déjà enregistrées : seul le modèle disparaît.''',
  ),
  GuideSection(
    icon: Icons.query_stats_outlined,
    title: 'Simulation long terme',
    body: '''
Des scénarios "et si" sur plusieurs années (jusqu'à 40 ans) : préparer une retraite, un changement de situation, un achat important... Contrairement au mode simulation du Budget (qui ne porte que sur un mois), l'horizon ici est long terme.

Un scénario est un ensemble nommé d'ajustements, totalement indépendant de vos vraies opérations : le créer, le renommer, le dupliquer ou le supprimer ne touche jamais vos données réelles ni les autres scénarios. Le bouton "Dupliquer ce scénario" recopie l'intégralité de ses réglages (opérations désactivées/modifiées, opérations virtuelles, événements ponctuels, retour à l'équilibre) dans une copie indépendante - pratique pour comparer deux variantes proches (ex. "et si je pars 2 ans plus tôt ?") sans tout reconstruire à la main.

Dans chaque scénario, trois leviers combinables, opération par opération :
• Désactiver une opération récurrente réelle à partir d'une date donnée, ou remplacer son montant projeté - sans jamais modifier l'opération réelle elle-même.
• Ajouter une opération récurrente virtuelle qui n'existe que dans ce scénario (ex. "pension de retraite +1200€/mois à partir de 2035"), avec en option une variation aléatoire d'un mois à l'autre et une augmentation annuelle composée, comme pour une vraie opération récurrente.
• Ajouter un événement ponctuel, une seule fois (ex. "capital +50000€ le 01/06/2035").

Chaque compte coché a sa propre paire de courbes, d'une couleur qui lui est propre : un trait plein "sans changement" (le calendrier réel projeté tel quel) et un trait pointillé "avec ce scénario". La case "Masquer les courbes sans changement" limite l'affichage aux comptes que le scénario modifie réellement, pour ne pas noyer le graphique de lignes qui se superposent.

Ajustement réaliste (dépenses imprévues) - icône 📈, par compte : le calcul de base ne connaît que les opérations récurrentes réelles, jamais les dépenses variables (nourriture, imprévus, essence...). Ce réglage calcule automatiquement, depuis l'historique réel de ce compte sur 12, 24 ou 36 mois au choix, l'écart moyen entre ce qui s'est vraiment passé et ce que les opérations récurrentes seules auraient laissé prévoir, puis l'ajoute chaque mois à la projection - avec un curseur de variation aléatoire pour ne pas simuler un montant identique chaque mois, comme dans la réalité. C'est un point de départ chiffré, pas une invention : les deux curseurs (montant, variation) restent réglables à la main avant d'enregistrer.

Retour à l'équilibre - icône ⚖️, par compte : sur un horizon de plusieurs années, une simulation purement additive (opérations connues + ajustement réaliste) a tendance à dériver indéfiniment vers le haut ou vers le bas, alors qu'en pratique un compte réel ne s'éloigne jamais bien longtemps de sa fourchette habituelle - comparer plusieurs années d'historique réel montre qu'un surplus fini presque toujours par être dépensé, et qu'un mois serré se resserre encore (le solde en début de mois et la dépense réelle du mois suivant sont nettement corrélés négativement). Ce réglage corrige ce défaut : chaque mois, le solde projeté est tiré vers une valeur d'équilibre - calculée depuis l'historique réel, mais modifiable à la main - proportionnellement à l'écart constaté. Le curseur "force de rappel" règle l'intensité de cette correction (0% = aucun effet, 100% = revient pile sur l'équilibre chaque mois), et un second curseur ajoute une variation aléatoire calibrée sur la vraie volatilité historique du compte, pas un pourcentage arbitraire. Un interrupteur active ou désactive l'effet indépendamment de ces réglages, sans jamais les effacer - pratique pour comparer la projection avec et sans, ou couper temporairement l'effet le temps d'un essai.

Le bouton actualiser (icône 🔄) force un rafraîchissement complet du panneau si un ajout récent ailleurs dans l'application (une nouvelle opération récurrente, par exemple) ne semble pas encore pris en compte - en pratique la simulation se met déjà à jour toute seule dès qu'une donnée change, ce bouton est une sécurité supplémentaire pour lever le doute.

Le calcul lui-même reste 100% déterministe, jamais délégué à une IA : mêmes règles de projection que la prévision de solde du tableau de bord, augmentation annuelle des opérations récurrentes comprise - seuls les deux réglages "réalistes" ci-dessus injectent volontairement une part de hasard, et seulement celle que vous choisissez d'y mettre. Le panneau des ajustements peut être replié pour ne garder que le graphique en plein écran.''',
  ),
  GuideSection(
    icon: Icons.donut_large_outlined,
    title: 'Explorateur de dépenses',
    body: '''
Répartition des dépenses (ou revenus) par catégorie sur une période choisie, avec filtre par compte. Touchez une part du graphique ou une ligne de la légende pour voir le détail des transactions derrière.''',
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
    title: 'Catégories et Tiers (Paramètres)',
    body: '''
Catégories : deux niveaux seulement (catégorie et sous-catégorie, pas plus). Le menu "..." de chaque catégorie propose Renommer, Fusionner, Archiver/Réactiver et Supprimer.

Renommer ou déplacer une catégorie ne touche jamais aux transactions déjà enregistrées avec elle. "Fusionner" déplace tout (transactions, opérations récurrentes, budget) d'une catégorie vers une autre puis supprime la première - uniquement proposé si elle n'a pas de sous-catégorie. Une catégorie encore utilisée ne peut pas être supprimée : l'application explique précisément ce qui l'utilise et propose "Archiver" à la place, qui la cache des listes tout en gardant son historique intact.

Tiers : un écran équivalent, plus simple (pas de hiérarchie), pour renommer, fusionner ou supprimer un tiers.''',
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

Deux IA optionnelles (Paramètres) peuvent prendre le relais pour des formulations beaucoup plus libres, ou une vraie question d'analyse ("analyse mes dépenses liées aux vacances sur les 3 derniers mois") :
• IA locale : sur ordinateur, un modèle téléchargé et exécuté sur votre machine, sans connexion internet. Sur navigateur web, elle parle à un serveur llama.cpp que vous faites tourner vous-même sur votre PC (adresse à renseigner dans Paramètres > IA locale).
• IA cloud : un service compatible OpenAI (ex. OpenRouter) avec votre propre clé API, pour ne rien installer localement.

Dans les deux cas, l'IA ne fait jamais que choisir quoi calculer (et, en mode "accès complet aux données", écrire des requêtes en lecture seule) - jamais de calcul ni d'écriture laissés au modèle : le résultat vient toujours de vos vraies données.''',
  ),
  GuideSection(
    icon: Icons.lock_outline,
    title: 'Code PIN et sécurité',
    body: '''
Paramètres > Code PIN. Un code d'au moins 4 chiffres, demandé à chaque ouverture et à chaque retour au premier plan. Après plusieurs codes erronés (réglable), l'application se verrouille temporairement (durée réglable elle aussi).

Il n'existe aucune récupération en cas de code oublié - si vous le perdez, il n'y a pas de "code oublié". Le code, comme tous les autres réglages, est stocké chiffré à côté du fichier .mmb (voir la section suivante) : il est donc le même sur tous vos appareils qui ouvrent ce fichier.

Un verrouillage automatique par inactivité (durée réglable, désactivé par défaut) peut aussi verrouiller l'application après un moment sans interaction, sans attendre une vraie mise en arrière-plan.''',
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
  GuideSection(
    icon: Icons.system_update_outlined,
    title: 'Mises à jour',
    body: '''
L'application vérifie automatiquement, à chaque démarrage, si une nouvelle version est disponible. Sur ordinateur, l'installation se fait silencieusement après votre accord initial. Sur Android, une confirmation du système est toujours demandée pour installer l'APK téléchargé (Android l'exige, ce n'est pas contournable).''',
  ),
];
