import 'dart:convert';

import '../../../data/mmex_repository.dart';
import '../../../models/account.dart';
import '../../../models/category.dart';
import '../../../models/payee.dart';
import 'llama_server_client.dart';

/// Default value for Settings' editable "Prompt IA (accès complet aux
/// données)" - a from-scratch schema + strict-rules prompt for the
/// full-database-access query mode (see [answerViaFullSqlAccess]),
/// distinct from [chatMlPrompt]'s own fixed intent-extraction system
/// prompt in llama_server_client.dart: this one gives the model the real
/// MMEX schema and asks it to write SQL directly, instead of picking from
/// a closed kind/metric/groupBy vocabulary (QueryKind.adHoc) - explicit
/// 2026-08-07 decision ("j'en ai marre d'être limité sur la version IA").
///
/// Kept editable in Settings (not just a hardcoded constant) because the
/// right balance of strictness/flexibility for a given local model is
/// something only trying it against real questions can really tune -
/// LocalLlmSettingsCard resets to this exact text via a "Réinitialiser"
/// button rather than the user ever needing to reconstruct it by hand.
const defaultSqlSystemPrompt = '''
Tu es un générateur de requêtes SQL (SQLite) en lecture seule pour une base
de finances personnelles (format MMEX). Tu ne réponds JAMAIS toi-même à la
question : tu écris la ou les requêtes SQL SELECT qui, une fois exécutées,
donneront les données nécessaires pour y répondre. Une autre étape se charge
ensuite de formuler la réponse à partir des résultats réels de tes requêtes -
n'invente donc jamais de chiffre ici, seules les requêtes comptent.

Réponds UNIQUEMENT avec un objet JSON de l'une de ces formes :
{"sql": "SELECT ..."}
pour une seule requête, ou :
{"steps": [{"objectif": "ce que cette requête doit donner", "sql": "SELECT ..."}, ...]}
pour plusieurs requêtes (1 à N) - utile quand la question demande à la fois
un total ET un détail, ou plusieurs angles sur les mêmes données. Chaque
"objectif" est une courte étiquette en français décrivant ce que la requête
fournit ; chaque "sql" est une requête SELECT distincte, exécutée l'une
après l'autre.
ou, si la question ne peut pas être répondue avec ce schéma :
{"sql": null, "raison": "..."}

Règles strictes :
- Dialecte SQLite uniquement. Chaque requête est UNE seule instruction
  SELECT (ou WITH ... SELECT), jamais de point-virgule, jamais
  d'instruction d'écriture (INSERT/UPDATE/DELETE/DROP/ALTER/CREATE/
  PRAGMA/ATTACH...).
- Pour un rapport exhaustif ou une analyse (répartition, bilan, détail sur
  plusieurs mois/années), AGREGUE en SQL (GROUP BY année, GROUP BY
  catégorie, top N via ORDER BY ... LIMIT) plutôt que de renvoyer des
  milliers de lignes brutes : les résultats sont passés tels quels à
  l'étape de réponse, et un résultat trop volumineux serait tronqué.
- Question thématique ("vacances", "travaux", "cadeaux"...) : cherche
  d'abord le thème dans les NOMS DE CATÉGORIE (CATEGNAME sur CATEGORY_V1,
  jointe par CATEGID), jamais par le texte des NOTES - les notes sont trop
  imprévisibles pour servir de base.
  **IMPORTANT : CATEGNAME ne contient JAMAIS le chemin complet "Parent:
  Enfant" - toujours le seul nom de la catégorie elle-même (le segment
  après le dernier ":"), même quand une sous-catégorie apparaît sous la
  forme "Loisirs:Vacances" dans le vocabulaire ci-dessous.** Pour une
  recherche LIKE par thème, utilise seulement le mot-clé
  (`LIKE '%vacance%'`) - JAMAIS le chemin complet
  (`LIKE '%Loisirs:Vacances%'` ne trouvera jamais rien, même si la
  catégorie existe bien).
  **IMPORTANT, et ceci s'applique à TOUTE requête thématique - un total,
  une liste d'opérations, un détail par mois, peu importe la forme :
  une catégorie qui a des sous-catégories (ex. "Vacances" avec les
  sous-catégories "Logement", "Resto", "Transports"...) sert souvent de
  simple regroupement - la plupart des vraies opérations sont
  enregistrées directement sur une SOUS-catégorie (CATEGID d'"Resto", pas
  celui de "Vacances"), dont le nom ne contient PAS forcément le mot du
  thème. Un filtre `CATEGNAME LIKE '%vacance%'` seul (sans la jointure
  vers le parent ci-dessous) ne trouve donc que les rares opérations
  classées directement sur la catégorie parente, et RATE tout ce qui est
  classé sur ses sous-catégories - que ce soit pour un total (une
  sous-estimation massive et silencieuse) ou pour une simple liste
  d'opérations (une liste vide ou incomplète alors que les opérations
  existent bel et bien). N'écris JAMAIS une requête thématique - même une
  simple liste - sans cette jointure vers le parent. Pour un thème qui
  correspond à une catégorie ayant des sous-catégories (regarde le
  vocabulaire ci-dessous, qui liste les chemins complets "Parent:Enfant"),
  inclut TOUJOURS aussi les opérations de ses sous-catégories, via une
  jointure vers la catégorie parente - que la requête calcule un total ou
  liste des opérations individuelles :
  SELECT SUM(T.TRANSAMOUNT) AS total
  FROM CHECKINGACCOUNT_V1 T
  JOIN CATEGORY_V1 C ON T.CATEGID = C.CATEGID
  LEFT JOIN CATEGORY_V1 P ON C.PARENTID = P.CATEGID
  WHERE (C.CATEGNAME LIKE '%vacance%' OR P.CATEGNAME LIKE '%vacance%')
    AND T.TRANSCODE = 'Withdrawal'
    AND (T.DELETEDTIME IS NULL OR T.DELETEDTIME = '') AND T.STATUS != 'V'
    AND T.TRANSDATE >= date('now', '-3 months').
  (`C.CATEGNAME LIKE '%vacance%'` attrape les opérations classées
  directement sur "Vacances" ; `P.CATEGNAME LIKE '%vacance%'` attrape
  celles classées sur une de ses sous-catégories comme "Resto". La même
  jointure `LEFT JOIN CATEGORY_V1 P ON C.PARENTID = P.CATEGID` et le même
  `WHERE (C.CATEGNAME LIKE ... OR P.CATEGNAME LIKE ...)` s'appliquent
  identiquement à une requête qui liste des opérations individuelles au
  lieu de sommer - seules les colonnes du SELECT changent.) Si tu dois
  filtrer sur le nom exact d'une sous-catégorie citée avec son chemin
  complet, ne compare que sur le segment après le ":"
  (`CATEGNAME = 'Vacances'`), jamais sur la chaîne complète. Si aucune
  catégorie existante ne correspond au thème, réponds {"sql": null,
  "raison": "aucune catégorie ne correspond"} plutôt que de deviner.
  **Second exemple, pour bien fixer le principe : "mes dépenses en
  nourriture depuis janvier 2026, mois par mois, détail par
  sous-catégories" - "Nourriture" a des sous-catégories ("Alimentation",
  "Boulangerie", "Restaurant"...) dont le nom ne contient PAS "nourriture"
  - la même jointure vers le parent s'applique, avec la même exigence de
  parenthèses autour du OR :**
  {"steps": [
    {"objectif": "Total par mois", "sql":
      "SELECT strftime('%Y-%m', T.TRANSDATE) AS mois, SUM(T.TRANSAMOUNT) AS total FROM CHECKINGACCOUNT_V1 T JOIN CATEGORY_V1 C ON T.CATEGID = C.CATEGID LEFT JOIN CATEGORY_V1 P ON C.PARENTID = P.CATEGID WHERE (C.CATEGNAME LIKE '%nourriture%' OR P.CATEGNAME LIKE '%nourriture%') AND T.TRANSCODE = 'Withdrawal' AND (T.DELETEDTIME IS NULL OR T.DELETEDTIME = '') AND T.STATUS != 'V' AND T.TRANSDATE >= '2026-01-01' GROUP BY mois ORDER BY mois"},
    {"objectif": "Détail par mois et sous-catégorie", "sql":
      "SELECT strftime('%Y-%m', T.TRANSDATE) AS mois, C.CATEGNAME AS sous_categorie, SUM(T.TRANSAMOUNT) AS total FROM CHECKINGACCOUNT_V1 T JOIN CATEGORY_V1 C ON T.CATEGID = C.CATEGID LEFT JOIN CATEGORY_V1 P ON C.PARENTID = P.CATEGID WHERE (C.CATEGNAME LIKE '%nourriture%' OR P.CATEGNAME LIKE '%nourriture%') AND T.TRANSCODE = 'Withdrawal' AND (T.DELETEDTIME IS NULL OR T.DELETEDTIME = '') AND T.STATUS != 'V' AND T.TRANSDATE >= '2026-01-01' GROUP BY mois, sous_categorie ORDER BY mois"}
  ]}
  (Remarque le `C.CATEGNAME` dans le SELECT de la deuxième requête - c'est
  lui qui donne le nom réel de la sous-catégorie, pas "Nourriture" répété
  partout : sans cette colonne, impossible de répondre "détail par
  sous-catégorie" même si la jointure vers le parent est correcte. Et
  remarque que la jointure vers le parent est présente ET les parenthèses
  autour du OR sont là dans les DEUX requêtes du plan, pas seulement la
  première.)
- Le vocabulaire réel de la base de l'utilisateur (comptes, catégories,
  tiers) est joint en bas de ce prompt, à titre indicatif pour savoir ce
  qui existe vraiment (et éviter de deviner un nom proche mais faux) - les
  catégories y sont affichées en chemin complet "Parent:Enfant"
  uniquement pour montrer la hiérarchie, jamais comme valeur littérale à
  comparer à CATEGNAME (voir la règle ci-dessus).
- N'utilise QUE les tables et colonnes listées ci-dessous. N'invente jamais
  un nom de table ou de colonne absent de cette liste.
- Les montants (TRANSAMOUNT, TOTRANSAMOUNT, INITIALBAL...) sont toujours des
  nombres positifs : le sens (dépense/revenu) vient de TRANSCODE, jamais du
  signe.
- Une opération annulée a STATUS = 'V' (majuscule) - à exclure des totaux
  sauf si la question porte explicitement dessus. Une opération supprimée a
  DELETEDTIME renseigné (non vide) - à exclure. **IMPORTANT : sur les
  lignes NON supprimées, DELETEDTIME vaut soit NULL soit '' selon la
  ligne (jamais un seul des deux de façon fiable) - un filtre
  `DELETEDTIME = ''` seul ignore silencieusement toutes les lignes où
  c'est NULL, ce qui peut exclure la quasi-totalité des vraies données.**
  Filtre toujours avec `(DELETEDTIME IS NULL OR DELETEDTIME = '')` pour
  "non supprimée", jamais `DELETEDTIME = ''` seul.
- Les dates (TRANSDATE, NEXTOCCURRENCEDATE...) sont stockées en texte, le
  plus souvent 'AAAA-MM-JJTHH:MM:SS' mais parfois juste 'AAAA-MM-JJ' selon
  la ligne. Une comparaison par plage (>=, <, BETWEEN avec un texte
  'AAAA-MM-JJ') fonctionne dans les deux cas ; évite une égalité stricte
  (`TRANSDATE = 'AAAA-MM-JJ'`) qui raterait les lignes au format complet -
  préfère `TRANSDATE LIKE 'AAAA-MM-JJ%'` si tu dois cibler un jour précis.
  **IMPORTANT sur les parenthèses, règle absolue : dans TOUT WHERE, si tu
  écris `OR` en dehors d'une paire de parenthèses qui l'entoure déjà, ta
  requête est FAUSSE. Un `OR` ne doit JAMAIS apparaître nu entre deux
  `AND` - il doit toujours être entre parenthèses. Exemple concret pour
  "les opérations de novembre et décembre 2025" :
  FAUX (ne fais JAMAIS ça) :
  `WHERE (C.CATEGNAME LIKE '%vacance%' OR P.CATEGNAME LIKE '%vacance%')
    AND T.TRANSDATE LIKE '2025-11%' OR T.TRANSDATE LIKE '2025-12%'
    AND T.STATUS != 'V'`
  (le `OR T.TRANSDATE LIKE '2025-12%'` ici est nu, pas entouré de
  parenthèses - SQL le lit comme "(tout ce qui précède) OU (décembre ET
  pas annulé)", ce qui retourne des opérations de n'importe quelle
  catégorie en décembre, et perd le filtre catégorie/statut pour
  novembre.)
  CORRECT (fais toujours ça) :
  `WHERE (C.CATEGNAME LIKE '%vacance%' OR P.CATEGNAME LIKE '%vacance%')
    AND (T.TRANSDATE LIKE '2025-11%' OR T.TRANSDATE LIKE '2025-12%')
    AND T.STATUS != 'V'`
  (chaque groupe OR - catégorie, dates, comptes, tiers... - a sa PROPRE
  paire de parenthèses qui l'isole des AND autour de lui.) Avant de
  répondre, relis ta requête et vérifie qu'aucun `OR` n'est en dehors de
  parenthèses.
- Le "aujourd'hui" pertinent, si besoin, peut être obtenu via date('now') -
  ne suppose jamais une date fixe.
- Ne calcule jamais de solde de compte en sommant CHECKINGACCOUNT_V1 seule :
  il faut aussi ajouter ACCOUNTLIST_V1.INITIALBAL. Si la question porte sur
  un solde et que c'est trop complexe pour une seule requête, réponds
  sql: null plutôt que d'approximer.
- BILLSDEPOSITS_V1 est le calendrier des opérations récurrentes (des
  modèles), PAS des opérations déjà passées - ne mélange jamais les deux
  dans une même requête sauf si la question le demande explicitement.
- Si la question est ambiguë, incomplète, ou sort du cadre de ce schéma,
  réponds {"sql": null, "raison": "..."} plutôt que de deviner.

Schéma disponible (SQLite, colonnes principales seulement) :

CHECKINGACCOUNT_V1 (le grand livre - chaque ligne est une opération réelle)
  TRANSID INTEGER, ACCOUNTID INTEGER, TOACCOUNTID INTEGER (NULL sauf virement),
  PAYEEID INTEGER, CATEGID INTEGER (NULL possible),
  TRANSCODE TEXT ('Withdrawal'=dépense, 'Deposit'=revenu, 'Transfer'=virement),
  TRANSAMOUNT REAL (montant débité du compte ACCOUNTID, toujours positif),
  TOTRANSAMOUNT REAL (montant crédité sur TOACCOUNTID pour un virement),
  STATUS TEXT (''=normal, 'R'=pointée, 'V'=annulée),
  TRANSDATE TEXT ('AAAA-MM-JJ' ou 'AAAA-MM-JJTHH:MM:SS' selon la ligne),
  NOTES TEXT,
  DELETEDTIME TEXT (NULL ou '' = pas supprimée, toute autre valeur = supprimée)

ACCOUNTLIST_V1 (les comptes)
  ACCOUNTID INTEGER, ACCOUNTNAME TEXT, ACCOUNTTYPE TEXT, STATUS TEXT ('Open'/'Closed'),
  INITIALBAL REAL, CURRENCYID INTEGER, FAVORITEACCT TEXT ('TRUE'/'FALSE')

CATEGORY_V1 (les catégories, une seule sous-catégorie de profondeur)
  CATEGID INTEGER, CATEGNAME TEXT, PARENTID INTEGER (NULL ou -1 = catégorie racine), ACTIVE INTEGER

PAYEE_V1 (les tiers)
  PAYEEID INTEGER, PAYEENAME TEXT, CATEGID INTEGER (catégorie par défaut), ACTIVE INTEGER

BILLSDEPOSITS_V1 (le calendrier des opérations récurrentes - des modèles, pas des opérations réelles)
  BDID INTEGER, ACCOUNTID INTEGER, TOACCOUNTID INTEGER, PAYEEID INTEGER, CATEGID INTEGER,
  TRANSCODE TEXT, TRANSAMOUNT REAL, TOTRANSAMOUNT REAL,
  NEXTOCCURRENCEDATE TEXT ('AAAA-MM-JJ', prochaine échéance), NUMOCCURRENCES INTEGER,
  NOTES TEXT

CURRENCYFORMATS_V1 (les devises)
  CURRENCYID INTEGER, CURRENCYNAME TEXT, CURRENCY_SYMBOL TEXT

APP_TRANSACTION_BILL_LINKS (extension de cette appli : lie une ligne de
CHECKINGACCOUNT_V1 à l'opération récurrente BILLSDEPOSITS_V1 dont elle est
issue, quand c'est le cas)
  TRANSID INTEGER, BILLID INTEGER

APP_PAUSED_TRANSACTIONS (extension de cette appli : opérations mises en
pause par l'utilisateur - déjà repérables via CHECKINGACCOUNT_V1.STATUS = 'V'
pour ces lignes précises, cette table sert surtout à retrouver leur statut
d'avant mise en pause)
  TRANSID INTEGER, WAS_RECONCILED INTEGER
''';

/// System prompt for the second call (grounded answer formatting) - fixed,
/// not user-editable like [defaultSqlSystemPrompt]: its only job is
/// faithfully paraphrasing data it's handed, nothing about the schema or
/// query strategy to tune here.
const _answerFormattingSystemPrompt = '''
Tu formules une réponse en français à partir des résultats de requêtes déjà
exécutés sur les données financières réelles de l'utilisateur - tu ne
calcules rien toi-même, tu ne fais que lire et reformuler ces données.
N'invente jamais un nombre absent des résultats fournis.

IMPORTANT sur les nombres : dans les résultats JSON fournis, un nombre comme
7.93 utilise le POINT comme séparateur DÉCIMAL (format JSON standard) - cela
représente sept euros et quatre-vingt-treize centimes, jamais sept mille
neuf cent trente. Convertis-le en notation française (virgule décimale) SANS
changer sa valeur : 7.93 devient "7,93 €", jamais "7 930,00 €". Ne multiplie
et ne divise jamais un montant en le reformattant - recopie exactement les
mêmes chiffres, seul le séparateur décimal change (point -> virgule).
''';

/// One executed step of a multi-step plan, ready to be handed to the
/// answer-formatting call (see [buildAnswerFormattingPrompt]).
class StepResult {
  final String objectif;
  final String rowsJson;
  final int rowCount;
  final bool truncated;

  const StepResult({
    required this.objectif,
    required this.rowsJson,
    required this.rowCount,
    required this.truncated,
  });
}

/// How much of the query results' JSON may reach the answer-formatting
/// model in total before individual results get truncated (with an
/// explicit notice, see [buildAnswerFormattingPrompt]) - a few hundred
/// aggregated rows fit comfortably in the model's context, thousands of
/// raw rows would not, and the SQL prompt already instructs aggregation
/// precisely to avoid hitting this.
const _resultBudgetChars = 60000;

/// Truncates [rows] to a whole number of rows whose JSON encoding fits
/// under [budget] - dropping rows from the end until it does, so the
/// model always receives *valid* JSON (never a mid-string/mid-number cut
/// that a model attempting to parse it literally would choke on). Returns
/// the (possibly shorter) row list and the total that was dropped.
({List<Map<String, Object?>> rows, int dropped}) _fitRowsToBudget(
  List<Map<String, Object?>> rows,
  int budget,
) {
  if (jsonEncode(rows).length <= budget) return (rows: rows, dropped: 0);
  int low = 0, high = rows.length;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (jsonEncode(rows.sublist(0, mid)).length <= budget) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return (rows: rows.sublist(0, low), dropped: rows.length - low);
}

/// Builds the second call's user-facing prompt: the question plus every
/// step's real result, labeled by its objectif, plus adaptive formatting
/// instructions - a plain, short answer for a simple question, or a
/// structured, exhaustive report (sections, bullets, per-category/per-
/// year detail, biggest items first) when the question asks for an
/// analysis/summary/breakdown. A truncated result is always announced
/// explicitly so the model knows its data is partial rather than
/// silently answering as if it were complete.
String buildAnswerFormattingPrompt(
  String question,
  List<StepResult> results, {
  required bool truncated,
}) {
  final isReport = RegExp(
    r'analyse|rapport|bilan|compte[- ]rendu|répartition|répartir|détail|évolutions?',
    caseSensitive: false,
  ).hasMatch(question);

  final buffer = StringBuffer()
    ..write('Question de l\'utilisateur : "$question"\n\n');
  for (final result in results) {
    buffer
      ..write(result.objectif.isEmpty
          ? 'Résultat exact de la requête SQL exécutée sur ses données '
            '(JSON, ${result.rowCount} ligne(s)) :\n'
          : 'Résultat de l\'étape « ${result.objectif} » (JSON, '
            '${result.rowCount} ligne(s)) :\n')
      ..write(result.rowsJson)
      ..write(result.truncated
          ? '\n(Ce résultat est partiel : des lignes supplémentaires ont '
            'été retirées pour rester dans la limite de place - ne réponds '
            'pas comme si ces lignes manquaient.)\n'
          : '')
      ..write('\n');
  }
  if (truncated) {
    buffer.write(
        'ATTENTION : au moins un des résultats ci-dessus a été '
        'tronqué par manque de place - tes données sont donc partielles, '
        'dis-le clairement dans ta réponse plutôt que de répondre comme '
        'si elles étaient complètes.\n\n');
  }
  if (isReport) {
    buffer.write(
        'Réponds à la question sous forme de rapport structuré en '
        'français, en te basant EXCLUSIVEMENT sur ces données : '
        'organise la réponse en sections avec titres et puces, donne le '
        'détail par catégorie et par année/mois quand les données le '
        'permettent, mets en évidence les plus gros postes, et termine '
        'par un total général quand il est calculable à partir des '
        'données fournies. Formate les montants avec 2 décimales et le '
        'symbole €. N\'invente aucun nombre absent des résultats '
        'fournis ; si un résultat est vide, dis-le clairement plutôt que '
        'de deviner.');
  } else {
    buffer.write(
        'Réponds à la question en une ou deux phrases claires, en '
        'français, en te basant EXCLUSIVEMENT sur ces données. Formate '
        'les montants avec 2 décimales et le symbole €. N\'invente aucun '
        'nombre absent des résultats fournis. Si un résultat est vide, '
        'dis-le clairement plutôt que de deviner une réponse.');
  }
  return buffer.toString();
}

/// Extracts and lightly sanity-checks the SQL from the model's JSON
/// response (see [defaultSqlSystemPrompt]'s output contract). The real
/// safety boundary is [MmexRepository.db] itself being opened with an
/// OS/SQLite-enforced `OpenMode.readOnly` connection (see
/// local_llm_manager_io.dart's `openReadOnlyAdHocRepository`, reused
/// unchanged for this mode too - a write attempt fails at the database
/// engine regardless of what this function does or misses) - this is just
/// quality control, so an obviously-wrong response (several statements, a
/// write keyword the model wrote despite instructions, prose instead of
/// SQL) fails closed with a clear "didn't understand" instead of a
/// confusing raw SQLite error surfacing to the user.
Map<String, dynamic>? _decodeJsonObject(String rawResponse) {
  try {
    final start = rawResponse.indexOf('{');
    final end = rawResponse.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) return null;
    final decoded = jsonDecode(rawResponse.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// True if [sql] has a WHERE clause that mixes AND and OR at the same
/// top-level nesting depth within that clause (outside any parentheses) -
/// e.g. `WHERE ... AND a OR b AND ...`. SQL's operator precedence reads
/// that as `(... AND a) OR (b AND ...)`, not the "all of these conditions,
/// and either a or b" the model almost always means - a real, repeatedly-
/// observed failure mode of the local model (2026-08-23: it kept dropping
/// the parentheses around a multi-month `OR` date filter -
/// `TRANSDATE LIKE '2025-11%' OR TRANSDATE LIKE '2025-12%'` - despite
/// three increasingly explicit prompt rewrites asking it not to). Rather
/// than keep tuning the prompt against a model limitation that prompt
/// wording alone didn't fix, this is a hard static check: a query this
/// ambiguous fails closed (rejected, same as any other malformed plan)
/// rather than silently running with the wrong logic - a missed answer is
/// much safer than a wrong one for financial data. A WHERE clause using
/// only OR (no top-level AND) or only AND (no top-level OR) is
/// unambiguous and passes fine; only the combination at the same depth is
/// rejected. Deliberately scoped to WHERE clauses only (stopping at the
/// next top-level GROUP/ORDER/LIMIT/HAVING/UNION keyword, or a lower
/// paren depth than where the clause started) - a multi-condition JOIN...
/// ON (`ON a.x = b.x AND a.y = b.y`) is a completely different, unrelated
/// clause and must never trip this check. A query can have more than one
/// top-level WHERE (e.g. either side of a UNION); every one is checked.
/// Single-quoted string literals (including doubled `''` as an escaped
/// quote) are skipped so a NOTES/PAYEENAME value containing "and"/"or" or
/// a literal parenthesis can never corrupt the depth count.
bool _hasAmbiguousTopLevelOrAnd(String sql) {
  var depth = 0;
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == "'") {
      i++;
      while (i < sql.length) {
        if (sql[i] == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch == '(') {
      depth++;
      i++;
      continue;
    }
    if (ch == ')') {
      if (depth > 0) depth--;
      i++;
      continue;
    }
    if (depth == 0 && RegExp(r'^WHERE\b', caseSensitive: false).hasMatch(sql.substring(i))) {
      final clauseStartDepth = depth;
      var j = i + 5; // past "WHERE"
      var clauseDepth = 0;
      var topLevelHasAnd = false;
      var topLevelHasOr = false;
      while (j < sql.length) {
        final cj = sql[j];
        if (cj == "'") {
          j++;
          while (j < sql.length) {
            if (sql[j] == "'") {
              if (j + 1 < sql.length && sql[j + 1] == "'") {
                j += 2;
                continue;
              }
              j++;
              break;
            }
            j++;
          }
          continue;
        }
        if (cj == '(') {
          clauseDepth++;
          j++;
          continue;
        }
        if (cj == ')') {
          if (clauseDepth == 0) break; // closes an enclosing paren - clause ends here
          clauseDepth--;
          j++;
          continue;
        }
        if (clauseDepth == 0) {
          final rest = sql.substring(j);
          if (RegExp(r'^(GROUP\s+BY|ORDER\s+BY|LIMIT|HAVING|UNION)\b',
                  caseSensitive: false)
              .hasMatch(rest)) {
            break;
          }
          if (RegExp(r'^AND\b', caseSensitive: false).hasMatch(rest)) {
            topLevelHasAnd = true;
            j += 3;
            continue;
          }
          if (RegExp(r'^OR\b', caseSensitive: false).hasMatch(rest)) {
            topLevelHasOr = true;
            j += 2;
            continue;
          }
        }
        j++;
      }
      if (topLevelHasAnd && topLevelHasOr) return true;
      depth = clauseStartDepth;
      i = j;
      continue;
    }
    i++;
  }
  return false;
}

/// The shared SELECT-only safety check used by both [extractValidatedSql]
/// and [extractValidatedSqlPlan] - see [extractValidatedSql]'s own doc
/// for why this is quality control on top of the OS-enforced read-only
/// connection, not the real safety boundary.
String? _validateSqlText(String? sql) {
  final trimmed = sql?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.contains(';')) return null; // no stacked/multiple statements
  final upper = trimmed.toUpperCase();
  if (!RegExp(r'^\s*(SELECT|WITH)\b').hasMatch(upper)) return null;
  const forbidden = [
    'INSERT', 'UPDATE', 'DELETE', 'DROP', 'ALTER', 'CREATE', 'REPLACE',
    'TRUNCATE', 'ATTACH', 'DETACH', 'PRAGMA', 'VACUUM', 'REINDEX',
    'ANALYZE', 'BEGIN', 'COMMIT', 'ROLLBACK', 'SAVEPOINT', 'RELEASE', 'EXEC',
  ];
  for (final word in forbidden) {
    if (RegExp('\\b$word\\b').hasMatch(upper)) return null;
  }
  if (_hasAmbiguousTopLevelOrAnd(trimmed)) return null;
  return trimmed;
}

String? extractValidatedSql(String rawResponse) {
  final json = _decodeJsonObject(rawResponse);
  if (json == null) return null;
  return _validateSqlText(json['sql'] as String?);
}

/// One validated step of a multi-step plan (see
/// [extractValidatedSqlPlan]'s doc for the full contract).
class SqlQueryStep {
  final String objectif;
  final String sql;

  const SqlQueryStep({required this.objectif, required this.sql});
}

/// Same as [extractValidatedSql], but accepts both of
/// [defaultSqlSystemPrompt]'s accepted response shapes:
/// `{"sql": "..."}` (wrapped as a single, unlabeled step) or
/// `{"steps": [{"objectif": "...", "sql": "..."}, ...]}` (1 to N steps,
/// order preserved). Every step's SQL goes through the exact same
/// SELECT-only validation as [extractValidatedSql] - a single bad step
/// fails the whole plan closed with null, never a partial execution.
/// A plan with more steps than this is rejected outright rather than
/// truncated: each step is a separate sequential database query, so an
/// unbounded count would let one question turn into an arbitrarily long
/// chain of queries with no way for the user to tell "still working" from
/// "hung". Four is plenty for the realistic "total + per-category +
/// per-month" shape this feature exists for.
const _maxSqlPlanSteps = 4;

List<SqlQueryStep>? extractValidatedSqlPlan(String rawResponse) {
  final json = _decodeJsonObject(rawResponse);
  if (json == null) return null;

  if (json.containsKey('steps')) {
    final rawSteps = json['steps'];
    if (rawSteps is! List || rawSteps.isEmpty) return null;
    if (rawSteps.length > _maxSqlPlanSteps) return null;
    final steps = <SqlQueryStep>[];
    for (final raw in rawSteps) {
      if (raw is! Map<String, dynamic>) return null;
      final sql = _validateSqlText(raw['sql'] as String?);
      if (sql == null) return null;
      final objectif = (raw['objectif'] as String?)?.trim() ?? '';
      steps.add(SqlQueryStep(
          objectif: objectif.isEmpty ? 'résultat' : objectif, sql: sql));
    }
    return steps;
  }

  final sql = _validateSqlText(json['sql'] as String?);
  if (sql == null) return null;
  return [SqlQueryStep(objectif: '', sql: sql)];
}

/// One exchange already shown in the chat transcript (nl_query_dialog.dart)
/// - the model never sees anything else about earlier turns, no chat-
/// history feature of llama.cpp's own `/completion` endpoint is used here,
/// just this app-owned recap prepended to the next question (see
/// [_formatHistory]). Deliberately excludes any answer that came from the
/// old fixed-kind pipeline (QueryKind.balance/outlook/incomeVsExpense) or
/// the plain rule-based parser - those never call into this file at all,
/// so a follow-up after one of those starts this chat's history fresh.
class ChatTurn {
  final String question;
  final String answer;

  const ChatTurn({required this.question, required this.answer});
}

/// How many of the most recent [ChatTurn]s are actually included - older
/// turns are dropped rather than kept forever, so a long-running
/// conversation can't slowly crowd the SQL-writing prompt's context budget
/// out from under the schema/vocabulary it actually needs on every turn.
const _maxHistoryTurns = 6;

/// Recaps the last few turns of the conversation so the model can resolve
/// a follow-up question ("et sur les 3 dernières années ?", "et pour
/// Boursorama ?") against what was just discussed - prepended to the new
/// question before it ever reaches [LlamaServerClient.askWithSystemPrompt].
/// Only the SQL-writing call gets this: the answer-formatting call already
/// receives the *current* question's real query results fresh every time,
/// and doesn't need yesterday's numbers repeated into it too.
String _formatHistory(List<ChatTurn> history) {
  if (history.isEmpty) return '';
  final recent = history.length > _maxHistoryTurns
      ? history.sublist(history.length - _maxHistoryTurns)
      : history;
  final buffer = StringBuffer(
      'Voici les derniers échanges de la conversation, pour comprendre une '
      'éventuelle question de suivi (mais ne réponds qu\'à la toute '
      'dernière question ci-dessous) :\n');
  for (final turn in recent) {
    buffer
      ..write('Utilisateur : ${turn.question}\n')
      ..write('Toi : ${turn.answer}\n');
  }
  buffer.write('\nNouvelle question de l\'utilisateur : ');
  return buffer.toString();
}

/// Two-call flow, the "full data access" alternative to the closed
/// QueryKind.adHoc vocabulary: (1) ask the model to write SQL against
/// [systemPrompt]'s schema - either one query or a multi-step plan (see
/// [extractValidatedSqlPlan]) - validate every step, then run each one in
/// order, wrapped as a subquery (which forces the whole thing to parse as
/// a single SELECT expression) against [readOnlyRepo] (always an
/// OS-enforced read-only connection, never the app's own read-write repo -
/// see local_llm_manager_io.dart's `openReadOnlyAdHocRepository`); (2) ask
/// the model again, this time grounded in the *exact* returned rows of
/// every step, to phrase the final French answer. A second, separate call
/// rather than reusing the SQL-writing response on purpose - the model is
/// never in a position to "answer" before real data exists, only to
/// paraphrase what's actually there, which is the whole anti-hallucination
/// point.
///
/// [history] (2026-08-23) lets a follow-up question in the same chat
/// session ("et l'an dernier ?") be resolved against what was just asked -
/// see [_formatHistory]. Empty by default: every existing single-question
/// caller keeps working unchanged.
///
/// Returns null (never throws) on any failure at either step - invalid/
/// missing SQL in any step, a query that errors against the real schema,
/// an empty model response - same never-throws contract as every other
/// local-AI entry point here, so the caller (nl_query_dialog.dart) always
/// has a safe fallback.
Future<String?> answerViaFullSqlAccess({
  required String question,
  required MmexRepository readOnlyRepo,
  required String systemPrompt,
  required LlamaServerClient engine,
  List<ChatTurn> history = const [],
}) async {
  try {
    final rawPlan = await engine.askWithSystemPrompt(
        systemPrompt, '${_formatHistory(history)}$question');
    final plan = extractValidatedSqlPlan(rawPlan);
    if (plan == null) return null;

    final results = <StepResult>[];
    var anyTruncated = false;
    for (final step in plan) {
      final rawRows = readOnlyRepo.db
          .query('SELECT * FROM (${step.sql}) LIMIT 5000');
      final fit = _fitRowsToBudget(rawRows, _resultBudgetChars);
      final truncated = fit.dropped > 0;
      if (truncated) anyTruncated = true;
      results.add(StepResult(
        objectif: step.objectif,
        rowsJson: jsonEncode(fit.rows),
        rowCount: fit.rows.length,
        truncated: truncated,
      ));
    }

    final formattingPrompt = buildAnswerFormattingPrompt(
      question,
      results,
      truncated: anyTruncated,
    );
    final answer = await engine.askFreeformWithSystemPrompt(
      _answerFormattingSystemPrompt,
      formattingPrompt,
    );
    final trimmed = answer.trim();
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    return null;
  }
}

/// How many payee names at most make it into the vocabulary appendix -
/// a database with hundreds of payees would otherwise bloat the system
/// prompt (and every HTTP request carrying it) with a line that's mostly
/// noise the model will never use, since a question names at most one or
/// two of them. Accounts and categories are small enough to keep whole.
const _maxPayeesInVocabulary = 150;

/// Formats the real, currently-open database's vocabulary (accounts,
/// category full paths "Parent:Enfant", payees) as a short appendix for
/// the SQL system prompt - see [buildEffectiveSqlSystemPrompt].
String _formatRealVocabulary({
  required List<Account> accounts,
  required List<Category> categories,
  List<Payee> payees = const [],
}) {
  final buffer = StringBuffer();
  if (accounts.isNotEmpty) {
    buffer
      ..write('\n\nVocabulaire réel de la base de l\'utilisateur '
          '(utilise EXACTEMENT ces noms) :')
      ..write('\nComptes : ${accounts.map((a) => a.name).join(', ')}');
  }
  if (categories.isNotEmpty) {
    final byId = {for (final c in categories) c.id: c};
    final paths = categories
        .map((c) => categoryFullPath(c.id, byId))
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    buffer.write('\nCatégories (chemin complet) : ${paths.join(', ')}');
  }
  if (payees.isNotEmpty) {
    final names = payees.map((p) => p.name).toSet().toList()..sort();
    final shown = names.length > _maxPayeesInVocabulary
        ? '${names.take(_maxPayeesInVocabulary).join(', ')} '
            '... (${names.length - _maxPayeesInVocabulary} autres, '
            'recherche-les via PAYEE_V1)'
        : names.join(', ');
    buffer.write('\nTiers : $shown');
  }
  return buffer.toString();
}

/// [defaultSqlSystemPrompt] (or the user's own edited version from
/// Settings) plus the real vocabulary of the currently-open database
/// appended at the bottom - a pure function of its inputs, computed fresh
/// at question time and never persisted, so "Réinitialiser" in Settings
/// still restores exactly [defaultSqlSystemPrompt] and this appendix can
/// never go stale or leak into AppPreferences.
String buildEffectiveSqlSystemPrompt(
  String basePrompt, {
  required List<Account> accounts,
  required List<Category> categories,
  List<Payee> payees = const [],
}) {
  final vocabulary = _formatRealVocabulary(
    accounts: accounts,
    categories: categories,
    payees: payees,
  );
  return vocabulary.isEmpty ? basePrompt : '$basePrompt$vocabulary';
}
