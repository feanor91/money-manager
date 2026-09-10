import 'package:json_annotation/json_annotation.dart';

part 'account.g.dart';

@JsonSerializable()
class Account {
  final int id;
  final String name;
  final String type; // Checking, Savings, Credit Card, Cash, Loan, Term, Asset, Investment
  final String status; // Open, Closed
  final double initialBalance;
  final int currencyId;
  final bool favorite;
  final String? notes;

  const Account({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.initialBalance,
    required this.currencyId,
    required this.favorite,
    this.notes,
  });

  factory Account.fromRow(Map<String, Object?> row) {
    return Account(
      id: row['ACCOUNTID'] as int,
      name: row['ACCOUNTNAME'] as String? ?? '',
      type: row['ACCOUNTTYPE'] as String? ?? 'Checking',
      status: row['STATUS'] as String? ?? 'Open',
      initialBalance: (row['INITIALBAL'] as num?)?.toDouble() ?? 0,
      currencyId: row['CURRENCYID'] as int? ?? 1,
      favorite: (row['FAVORITEACCT'] as String? ?? 'FALSE') == 'TRUE',
      notes: row['NOTES'] as String?,
    );
  }

  /// Sérialisation JSON pour l'API client/serveur (voir
  /// PLAN_ARCHITECTURE_CLIENT_SERVEUR.md) - générée par json_serializable
  /// plutôt qu'écrite à la main, pour ne pas reproduire "le bug n°1" déjà
  /// documenté dans CLAUDE.md (un champ ajouté au modèle, oublié dans un
  /// toJson manuel, silencieusement jamais envoyé).
  factory Account.fromJson(Map<String, dynamic> json) => _$AccountFromJson(json);
  Map<String, dynamic> toJson() => _$AccountToJson(this);
}
