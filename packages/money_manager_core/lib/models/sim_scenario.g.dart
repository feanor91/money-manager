// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sim_scenario.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SimScenario _$SimScenarioFromJson(Map<String, dynamic> json) => SimScenario(
  id: (json['id'] as num).toInt(),
  name: json['name'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  assumedFinalBalance: (json['assumedFinalBalance'] as num?)?.toDouble(),
);

Map<String, dynamic> _$SimScenarioToJson(SimScenario instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
      'assumedFinalBalance': instance.assumedFinalBalance,
    };

SimBillOverride _$SimBillOverrideFromJson(Map<String, dynamic> json) =>
    SimBillOverride(
      scenarioId: (json['scenarioId'] as num).toInt(),
      billId: (json['billId'] as num).toInt(),
      disabledFrom: json['disabledFrom'] == null
          ? null
          : DateTime.parse(json['disabledFrom'] as String),
      amountOverride: (json['amountOverride'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$SimBillOverrideToJson(SimBillOverride instance) =>
    <String, dynamic>{
      'scenarioId': instance.scenarioId,
      'billId': instance.billId,
      'disabledFrom': instance.disabledFrom?.toIso8601String(),
      'amountOverride': instance.amountOverride,
    };

SimVirtualBill _$SimVirtualBillFromJson(Map<String, dynamic> json) =>
    SimVirtualBill(
      id: (json['id'] as num).toInt(),
      scenarioId: (json['scenarioId'] as num).toInt(),
      accountId: (json['accountId'] as num).toInt(),
      label: json['label'] as String,
      transCode: $enumDecode(_$TransCodeEnumMap, json['transCode']),
      amount: (json['amount'] as num).toDouble(),
      startDate: DateTime.parse(json['startDate'] as String),
      period: $enumDecode(_$RecurrencePeriodEnumMap, json['period']),
      numOccurrences: (json['numOccurrences'] as num?)?.toInt() ?? -1,
      variancePercent: (json['variancePercent'] as num?)?.toDouble() ?? 0,
      annualIncreasePercent:
          (json['annualIncreasePercent'] as num?)?.toDouble() ?? 0,
      annualIncreaseAnchor: json['annualIncreaseAnchor'] == null
          ? null
          : DateTime.parse(json['annualIncreaseAnchor'] as String),
    );

Map<String, dynamic> _$SimVirtualBillToJson(SimVirtualBill instance) =>
    <String, dynamic>{
      'id': instance.id,
      'scenarioId': instance.scenarioId,
      'accountId': instance.accountId,
      'label': instance.label,
      'transCode': _$TransCodeEnumMap[instance.transCode]!,
      'amount': instance.amount,
      'startDate': instance.startDate.toIso8601String(),
      'period': _$RecurrencePeriodEnumMap[instance.period]!,
      'numOccurrences': instance.numOccurrences,
      'variancePercent': instance.variancePercent,
      'annualIncreasePercent': instance.annualIncreasePercent,
      'annualIncreaseAnchor': instance.annualIncreaseAnchor?.toIso8601String(),
    };

const _$TransCodeEnumMap = {
  TransCode.withdrawal: 'withdrawal',
  TransCode.deposit: 'deposit',
  TransCode.transfer: 'transfer',
};

const _$RecurrencePeriodEnumMap = {
  RecurrencePeriod.none: 'none',
  RecurrencePeriod.weekly: 'weekly',
  RecurrencePeriod.biWeekly: 'biWeekly',
  RecurrencePeriod.monthly: 'monthly',
  RecurrencePeriod.biMonthly: 'biMonthly',
  RecurrencePeriod.quarterly: 'quarterly',
  RecurrencePeriod.halfYearly: 'halfYearly',
  RecurrencePeriod.yearly: 'yearly',
  RecurrencePeriod.fourMonths: 'fourMonths',
  RecurrencePeriod.fourWeeks: 'fourWeeks',
  RecurrencePeriod.daily: 'daily',
  RecurrencePeriod.monthlyLastDay: 'monthlyLastDay',
  RecurrencePeriod.monthlyLastBusinessDay: 'monthlyLastBusinessDay',
  RecurrencePeriod.inXDays: 'inXDays',
  RecurrencePeriod.inXMonths: 'inXMonths',
  RecurrencePeriod.everyXDays: 'everyXDays',
  RecurrencePeriod.everyXMonths: 'everyXMonths',
};

SimOneOffEvent _$SimOneOffEventFromJson(Map<String, dynamic> json) =>
    SimOneOffEvent(
      id: (json['id'] as num).toInt(),
      scenarioId: (json['scenarioId'] as num).toInt(),
      accountId: (json['accountId'] as num).toInt(),
      label: json['label'] as String,
      transCode: $enumDecode(_$TransCodeEnumMap, json['transCode']),
      amount: (json['amount'] as num).toDouble(),
      date: DateTime.parse(json['date'] as String),
    );

Map<String, dynamic> _$SimOneOffEventToJson(SimOneOffEvent instance) =>
    <String, dynamic>{
      'id': instance.id,
      'scenarioId': instance.scenarioId,
      'accountId': instance.accountId,
      'label': instance.label,
      'transCode': _$TransCodeEnumMap[instance.transCode]!,
      'amount': instance.amount,
      'date': instance.date.toIso8601String(),
    };
