// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'account.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Account _$AccountFromJson(Map<String, dynamic> json) => Account(
  id: (json['id'] as num).toInt(),
  name: json['name'] as String,
  type: json['type'] as String,
  status: json['status'] as String,
  initialBalance: (json['initialBalance'] as num).toDouble(),
  currencyId: (json['currencyId'] as num).toInt(),
  favorite: json['favorite'] as bool,
  notes: json['notes'] as String?,
);

Map<String, dynamic> _$AccountToJson(Account instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'type': instance.type,
  'status': instance.status,
  'initialBalance': instance.initialBalance,
  'currencyId': instance.currencyId,
  'favorite': instance.favorite,
  'notes': instance.notes,
};
