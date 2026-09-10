// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'category.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Category _$CategoryFromJson(Map<String, dynamic> json) => Category(
  id: (json['id'] as num).toInt(),
  name: json['name'] as String,
  active: json['active'] as bool,
  parentId: (json['parentId'] as num?)?.toInt(),
);

Map<String, dynamic> _$CategoryToJson(Category instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'parentId': instance.parentId,
  'active': instance.active,
};

CategoryUsage _$CategoryUsageFromJson(Map<String, dynamic> json) =>
    CategoryUsage(
      childCategoryCount: (json['childCategoryCount'] as num).toInt(),
      transactionCount: (json['transactionCount'] as num).toInt(),
      recurringCount: (json['recurringCount'] as num).toInt(),
      budgetEntryCount: (json['budgetEntryCount'] as num).toInt(),
      payeeDefaultCount: (json['payeeDefaultCount'] as num).toInt(),
    );

Map<String, dynamic> _$CategoryUsageToJson(CategoryUsage instance) =>
    <String, dynamic>{
      'childCategoryCount': instance.childCategoryCount,
      'transactionCount': instance.transactionCount,
      'recurringCount': instance.recurringCount,
      'budgetEntryCount': instance.budgetEntryCount,
      'payeeDefaultCount': instance.payeeDefaultCount,
    };
