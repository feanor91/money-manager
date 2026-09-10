// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'currency.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

CurrencyFormat _$CurrencyFormatFromJson(Map<String, dynamic> json) =>
    CurrencyFormat(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String,
      prefixSymbol: json['prefixSymbol'] as String,
      suffixSymbol: json['suffixSymbol'] as String,
      decimalPoint: json['decimalPoint'] as String,
      groupSeparator: json['groupSeparator'] as String,
    );

Map<String, dynamic> _$CurrencyFormatToJson(CurrencyFormat instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'prefixSymbol': instance.prefixSymbol,
      'suffixSymbol': instance.suffixSymbol,
      'decimalPoint': instance.decimalPoint,
      'groupSeparator': instance.groupSeparator,
    };
