import 'dart:convert';

import '../../../data/mmex_repository.dart';
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
question : tu écris UNE SEULE requête SQL SELECT qui, une fois exécutée,
donnera les données nécessaires pour y répondre. Une autre étape se charge
ensuite de formuler la réponse à partir du résultat réel de ta requête -
n'invente donc jamais de chiffre ici, seule la requête compte.

Réponds UNIQUEMENT avec un objet JSON de la forme :
{"sql": "SELECT ..."}
ou, si la question ne peut pas être répondue avec ce schéma :
{"sql": null, "raison": "..."}

Règles strictes :
- Dialecte SQLite uniquement. Une seule instruction SELECT (ou WITH ... SELECT),
  jamais de point-virgule, jamais plusieurs requêtes, jamais d'instruction
  d'écriture (INSERT/UPDATE/DELETE/DROP/ALTER/CREATE/PRAGMA/ATTACH...).
- N'utilise QUE les tables et colonnes listées ci-dessous. N'invente jamais
  un nom de table ou de colonne absent de cette liste.
- Les montants (TRANSAMOUNT, TOTRANSAMOUNT, INITIALBAL...) sont toujours des
  nombres positifs : le sens (dépense/revenu) vient de TRANSCODE, jamais du
  signe.
- Une opération annulée a STATUS = 'V' (majuscule) - à exclure des totaux
  sauf si la question porte explicitement dessus. Une opération supprimée a
  DELETEDTIME non vide - toujours à exclure.
- Les dates (TRANSDATE, NEXTOCCURRENCEDATE...) sont stockées en texte
  'AAAA-MM-JJ'. Compare-les directement en tant que texte (>=, <, BETWEEN),
  jamais via une fonction de date incompatible SQLite.
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
  TRANSDATE TEXT ('AAAA-MM-JJ'), NOTES TEXT, DELETEDTIME TEXT (vide = pas supprimée)

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
Tu formules une réponse en français à partir d'un résultat de requête déjà
exécuté sur les données financières réelles de l'utilisateur - tu ne
calcules rien toi-même, tu ne fais que lire et reformuler ces données.
N'invente jamais un nombre absent du résultat fourni.
''';

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
String? extractValidatedSql(String rawResponse) {
  final Map<String, dynamic> json;
  try {
    final start = rawResponse.indexOf('{');
    final end = rawResponse.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) return null;
    final decoded = jsonDecode(rawResponse.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) return null;
    json = decoded;
  } catch (_) {
    return null;
  }
  final sql = (json['sql'] as String?)?.trim();
  if (sql == null || sql.isEmpty) return null;
  if (sql.contains(';')) return null; // no stacked/multiple statements
  final upper = sql.toUpperCase();
  if (!RegExp(r'^\s*(SELECT|WITH)\b').hasMatch(upper)) return null;
  const forbidden = [
    'INSERT', 'UPDATE', 'DELETE', 'DROP', 'ALTER', 'CREATE', 'REPLACE',
    'TRUNCATE', 'ATTACH', 'DETACH', 'PRAGMA', 'VACUUM', 'REINDEX',
    'ANALYZE', 'BEGIN', 'COMMIT', 'ROLLBACK', 'SAVEPOINT', 'RELEASE', 'EXEC',
  ];
  for (final word in forbidden) {
    if (RegExp('\\b$word\\b').hasMatch(upper)) return null;
  }
  return sql;
}

/// Two-call flow, the "full data access" alternative to the closed
/// QueryKind.adHoc vocabulary: (1) ask the model to write SQL against
/// [systemPrompt]'s schema, validate it, run it - wrapped as a subquery,
/// which both caps the row count and forces the whole thing to parse as a
/// single SELECT expression - against [readOnlyRepo] (always an
/// OS-enforced read-only connection, never the app's own read-write repo -
/// see local_llm_manager_io.dart's `openReadOnlyAdHocRepository`); (2) ask
/// the model again, this time grounded in the *exact* returned rows, to
/// phrase the final French answer. A second, separate call rather than
/// reusing the SQL-writing response on purpose - the model is never in a
/// position to "answer" before real data exists, only to paraphrase what's
/// actually there, which is the whole anti-hallucination point.
///
/// Returns null (never throws) on any failure at either step - invalid/
/// missing SQL, a query that errors against the real schema, an empty
/// model response - same never-throws contract as every other local-AI
/// entry point here, so the caller (nl_query_dialog.dart) always has a
/// safe fallback.
Future<String?> answerViaFullSqlAccess({
  required String question,
  required MmexRepository readOnlyRepo,
  required String systemPrompt,
  required LlamaServerClient engine,
}) async {
  try {
    final rawSql = await engine.askWithSystemPrompt(systemPrompt, question);
    final sql = extractValidatedSql(rawSql);
    if (sql == null) return null;

    final rows = readOnlyRepo.db.query('SELECT * FROM ($sql) LIMIT 500');
    final rowsJson = jsonEncode(rows);

    final formattingPrompt = 'Question de l\'utilisateur : "$question"\n\n'
        'Résultat exact de la requête SQL exécutée sur ses données (JSON, '
        '${rows.length} ligne(s)) :\n$rowsJson\n\n'
        'Réponds à la question en une ou deux phrases claires, en français, '
        'en te basant EXCLUSIVEMENT sur ces données. Formate les montants '
        'avec 2 décimales et le symbole €. N\'invente aucun nombre absent de '
        'ce résultat. Si le résultat est vide, dis-le clairement plutôt que '
        'de deviner une réponse.';
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
