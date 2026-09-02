# Plan : simulation long terme (retraite & scénarios sur les opérations récurrentes)

Document de planification, pas un engagement - voir ROADMAP.md. Objectif :
pouvoir simuler l'impact de changements sur les opérations récurrentes
(perte de revenu, nouvelle pension, arrêt d'une charge...) sur plusieurs
années, de façon **extrêmement fiable** (demande explicite de l'utilisateur,
2026-09-02) - donc en calcul déterministe, jamais via l'IA.

## Ce qui existe déjà et qu'on va réutiliser

L'appli a déjà tout le moteur de projection nécessaire, juste pas encore
exposé pour un scénario multi-années éditable :

- `MmexRepository.recurringMonthlyNet`/`recurringDailyNet`
  (`lib/data/mmex_repository.dart`) : projettent déjà les opérations
  récurrentes (BILLSDEPOSITS_V1) dans le futur, jour par jour ou mois par
  mois, sans limite de durée codée en dur (seulement un garde-fou anti-
  boucle-infinie à 1000 itérations par opération).
- `MmexRepository._occurrencesInRange` : la fonction qui fait vraiment
  avancer une opération récurrente dans le temps (gère les 4 types de
  périodicité MMEX, y compris les "tous les X jours/mois"). Privée
  actuellement - à exposer (ou envelopper publiquement) pour ce chantier.
- `ForecastChart` (`lib/widgets/forecast_chart.dart`) : le graphique
  solde réel (trait plein) + projection (pointillés) déjà utilisé sur le
  tableau de bord - bon modèle de rendu, mais plafonné à 1 an
  (`ForecastDuration.oneYear`).
- `PurchaseSimulationProvider` : le pattern existant pour une simulation
  *éphémère, non sauvegardée* (achat simulé sur le tableau de bord) -
  bon modèle pour un essai rapide "et si...", mais pas pour un vrai
  scénario qu'on veut retrouver plus tard.
- Le mode "Simulation" du budget (`budget_screen.dart`, `BudgetScenario`) :
  le pattern déjà en place pour un **scénario nommé, sauvegardé,
  modifiable** - comptes/tables `APP_BUDGET_SCENARIOS`,
  `APP_BUDGET_SCENARIO_AMOUNTS` (valeurs `MANUAL` tapées à la main vs
  auto-calculées), `APP_BUDGET_SCENARIO_VIRTUAL_CATEGORIES` (catégories
  qui n'existent que pour la simulation, aucune ligne MMEX réelle
  derrière). C'est exactement le même besoin ici, appliqué aux opérations
  récurrentes plutôt qu'aux catégories de budget - même convention de
  tables `APP_...` à suivre (créées dans `ensureAppSchema()`, jamais de
  modification du schéma MMEX lui-même).

Conclusion : **aucune nouvelle logique de calcul de date/récurrence à
inventer** - le travail principal est (1) une couche qui fusionne les
vraies opérations récurrentes avec les ajustements du scénario avant de
les donner au moteur de projection existant, et (2) l'interface pour
gérer ces ajustements et afficher le résultat sur plusieurs années.

## Ce qu'un scénario doit pouvoir faire

Un scénario nommé et sauvegardé (comme `BudgetScenario`), avec une liste
d'ajustements, chacun de l'un de ces trois types :

1. **Désactiver/modifier une opération récurrente réelle** à partir d'une
   date donnée (ex. "salaire arrêté le 01/06/2035", "loyer réduit de
   moitié à partir de 2036").
2. **Ajouter une opération récurrente virtuelle**, qui n'existe pas dans
   BILLSDEPOSITS_V1 (ex. "pension de retraite +1200€/mois à partir de
   2035") - même principe que les catégories virtuelles du budget.
3. **Un événement ponctuel** (ex. "capital de départ à la retraite
   +50000€ le 01/06/2035") - une seule occurrence, pas une récurrence.

Le calcul combine (opérations réelles non désactivées) + (opérations
virtuelles) + (événements ponctuels), puis réutilise le même moteur de
projection que le graphique existant pour produire un solde mois par
mois sur l'horizon choisi (années, pas juste mois).

## Questions ouvertes à trancher avant/pendant le développement

- **Hypothèses de rendement/inflation ?** Rester strictement sur les flux
  de trésorerie (revenus/dépenses récurrents, comme aujourd'hui) ou
  ajouter un taux de croissance annuel appliqué à l'épargne (ex. "mon
  épargne rapporte 2%/an") ? Ça change significativement la portée - à
  décider avec l'utilisateur, proposition par défaut : rester sur les
  flux de trésorerie pour une v1 fiable, le rendement pouvant être ajouté
  plus tard comme une option distincte, clairement signalée comme une
  hypothèse (pas un fait).
- **Un compte ou tous les comptes combinés ?** Les outils de prévision
  actuels sont par compte (`accountId`) ; une simulation retraite a
  probablement plus de sens sur un total combiné, ou au choix.
- **Comparer plusieurs scénarios en même temps** (plusieurs courbes sur
  le même graphique) ou un seul à la fois ?
- **Horizon nécessaire** - combien d'années avant la retraite ? Détermine
  les options de durée à proposer et sert à vérifier qu'il n'y a pas de
  souci d'arithmétique de dates sur un horizon aussi long (bissextiles,
  changements d'heure - déjà gérés par les helpers `_addMonths`/
  `_addDays` de `forecast_chart.dart`, mais à revérifier sur des décennies).

## Découpage proposé (plusieurs sessions)

1. ~~**Couche données + calcul (sans interface)**~~ - **fait (2026-09-02)**.
   Nouvelles tables `APP_SIM_SCENARIOS`/`APP_SIM_BILL_OVERRIDES`/
   `APP_SIM_VIRTUAL_BILLS`/`APP_SIM_ONE_OFF_EVENTS` (`ensureAppSchema()`),
   nouveaux modèles (`lib/models/sim_scenario.dart`) et CRUD complet côté
   `MmexRepository` (créer/renommer/supprimer un scénario, gérer ses
   ajustements). Le calcul lui-même
   (`MmexRepository.simulatedMonthlyNet`) réutilise **exactement** le même
   moteur de projection que `recurringMonthlyNet` (extrait dans une
   méthode partagée `_monthlyNetForBills`) - aucune nouvelle logique de
   date/récurrence, seulement une fusion (réel modifié/désactivé +
   virtuel + événements ponctuels) avant de repasser par le même code
   déjà utilisé par le graphique de prévision existant. 17 nouveaux tests
   (`test/sim_scenario_test.dart`), dont un qui vérifie explicitement
   qu'un scénario sans aucun ajustement projette *exactement* comme
   `recurringMonthlyNet` (aucune divergence silencieuse possible).
   `flutter analyze`/`flutter test` (457) propres. Pas encore d'interface
   - rien n'est accessible depuis l'appli pour l'instant, uniquement du
     code testé en coulisses.
2. **Interface minimale** - un scénario, liste d'ajustements, un
   graphique (réutilisant le rendu de `ForecastChart`) sur plusieurs
   années. Pas commencé - questions ouvertes ci-dessus toujours à trancher
   avant de s'y lancer (rendement/inflation, un compte ou tous, horizon).
3. **Finitions** - scénarios multiples, comparaison, export CSV de la
   projection (même pattern que l'export déjà existant du grand livre et
   des réponses IA). Pas commencé.
