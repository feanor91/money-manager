// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'transaction.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MoneyTransaction _$MoneyTransactionFromJson(Map<String, dynamic> json) =>
    MoneyTransaction(
      id: (json['id'] as num).toInt(),
      accountId: (json['accountId'] as num).toInt(),
      payeeId: (json['payeeId'] as num).toInt(),
      transCode: $enumDecode(_$TransCodeEnumMap, json['transCode']),
      amount: (json['amount'] as num).toDouble(),
      toAmount: (json['toAmount'] as num).toDouble(),
      status: json['status'] as String,
      date: DateTime.parse(json['date'] as String),
      toAccountId: (json['toAccountId'] as num?)?.toInt(),
      categoryId: (json['categoryId'] as num?)?.toInt(),
      notes: json['notes'] as String?,
    );

Map<String, dynamic> _$MoneyTransactionToJson(MoneyTransaction instance) =>
    <String, dynamic>{
      'id': instance.id,
      'accountId': instance.accountId,
      'toAccountId': instance.toAccountId,
      'payeeId': instance.payeeId,
      'transCode': _$TransCodeEnumMap[instance.transCode]!,
      'amount': instance.amount,
      'toAmount': instance.toAmount,
      'status': instance.status,
      'categoryId': instance.categoryId,
      'date': instance.date.toIso8601String(),
      'notes': instance.notes,
    };

const _$TransCodeEnumMap = {
  TransCode.withdrawal: 'withdrawal',
  TransCode.deposit: 'deposit',
  TransCode.transfer: 'transfer',
};

TransactionWithBalance _$TransactionWithBalanceFromJson(
  Map<String, dynamic> json,
) => TransactionWithBalance(
  MoneyTransaction.fromJson(json['transaction'] as Map<String, dynamic>),
  (json['balanceAfter'] as num).toDouble(),
);

Map<String, dynamic> _$TransactionWithBalanceToJson(
  TransactionWithBalance instance,
) => <String, dynamic>{
  'transaction': instance.transaction,
  'balanceAfter': instance.balanceAfter,
};
