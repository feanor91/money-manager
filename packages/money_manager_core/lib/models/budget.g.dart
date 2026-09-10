// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'budget.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BudgetEnvelope _$BudgetEnvelopeFromJson(Map<String, dynamic> json) =>
    BudgetEnvelope(
      id: (json['id'] as num).toInt(),
      accountId: (json['accountId'] as num).toInt(),
      categoryId: (json['categoryId'] as num).toInt(),
      amount: (json['amount'] as num).toDouble(),
      active: json['active'] as bool,
      name: json['name'] as String?,
      manualOverride: json['manualOverride'] as bool? ?? false,
    );

Map<String, dynamic> _$BudgetEnvelopeToJson(BudgetEnvelope instance) =>
    <String, dynamic>{
      'id': instance.id,
      'accountId': instance.accountId,
      'categoryId': instance.categoryId,
      'amount': instance.amount,
      'active': instance.active,
      'name': instance.name,
      'manualOverride': instance.manualOverride,
    };
