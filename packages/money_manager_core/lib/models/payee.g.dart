// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'payee.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Payee _$PayeeFromJson(Map<String, dynamic> json) => Payee(
  id: (json['id'] as num).toInt(),
  name: json['name'] as String,
  active: json['active'] as bool,
  categoryId: (json['categoryId'] as num?)?.toInt(),
);

Map<String, dynamic> _$PayeeToJson(Payee instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'categoryId': instance.categoryId,
  'active': instance.active,
};
