import 'package:json_annotation/json_annotation.dart';

part 'payee.g.dart';

@JsonSerializable()
class Payee {
  final int id;
  final String name;
  final int? categoryId;
  final bool active;

  const Payee({
    required this.id,
    required this.name,
    required this.active,
    this.categoryId,
  });

  factory Payee.fromRow(Map<String, Object?> row) {
    return Payee(
      id: row['PAYEEID'] as int,
      name: row['PAYEENAME'] as String? ?? '',
      active: (row['ACTIVE'] as int? ?? 1) == 1,
      categoryId: row['CATEGID'] as int?,
    );
  }

  factory Payee.fromJson(Map<String, dynamic> json) => _$PayeeFromJson(json);
  Map<String, dynamic> toJson() => _$PayeeToJson(this);
}
