// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bill_deposit.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BillDeposit _$BillDepositFromJson(Map<String, dynamic> json) => BillDeposit(
  id: (json['id'] as num).toInt(),
  accountId: (json['accountId'] as num).toInt(),
  payeeId: (json['payeeId'] as num).toInt(),
  transCode: $enumDecode(_$TransCodeEnumMap, json['transCode']),
  amount: (json['amount'] as num).toDouble(),
  toAmount: (json['toAmount'] as num).toDouble(),
  nextOccurrence: DateTime.parse(json['nextOccurrence'] as String),
  period: $enumDecode(_$RecurrencePeriodEnumMap, json['period']),
  autoExecute: $enumDecode(_$RecurrenceAutoExecuteEnumMap, json['autoExecute']),
  numOccurrences: (json['numOccurrences'] as num).toInt(),
  toAccountId: (json['toAccountId'] as num?)?.toInt(),
  categoryId: (json['categoryId'] as num?)?.toInt(),
  notes: json['notes'] as String?,
  paused: json['paused'] as bool? ?? false,
  variancePercent: (json['variancePercent'] as num?)?.toDouble() ?? 0,
  annualIncreasePercent:
      (json['annualIncreasePercent'] as num?)?.toDouble() ?? 0,
  annualIncreaseAnchor: json['annualIncreaseAnchor'] == null
      ? null
      : DateTime.parse(json['annualIncreaseAnchor'] as String),
);

Map<String, dynamic> _$BillDepositToJson(BillDeposit instance) =>
    <String, dynamic>{
      'id': instance.id,
      'accountId': instance.accountId,
      'toAccountId': instance.toAccountId,
      'payeeId': instance.payeeId,
      'transCode': _$TransCodeEnumMap[instance.transCode]!,
      'amount': instance.amount,
      'toAmount': instance.toAmount,
      'categoryId': instance.categoryId,
      'nextOccurrence': instance.nextOccurrence.toIso8601String(),
      'period': _$RecurrencePeriodEnumMap[instance.period]!,
      'autoExecute': _$RecurrenceAutoExecuteEnumMap[instance.autoExecute]!,
      'numOccurrences': instance.numOccurrences,
      'notes': instance.notes,
      'paused': instance.paused,
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

const _$RecurrenceAutoExecuteEnumMap = {
  RecurrenceAutoExecute.manual: 'manual',
  RecurrenceAutoExecute.silent: 'silent',
  RecurrenceAutoExecute.notify: 'notify',
};
