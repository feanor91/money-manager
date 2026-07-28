import 'package:intl/intl.dart';

/// Clamps [day] to the last real day of [year]/[month] (e.g. day 31 in a
/// 30-day month) - same trick used for the dashboard's forecast-day
/// balance.
DateTime _clampedDay(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDay ? lastDay : day);
}

/// A half-open budget window [start, end): begins on the "Jour de
/// prevision du solde" (Settings) rather than the 1st of the month, so it
/// lines up with the user's own pay cycle instead of the calendar. Named
/// after the month its *last* included day falls in - a window from 24
/// June to 23 July is "Juillet", since that's the month most of its
/// spending actually happened in.
class BudgetWindow {
  final DateTime start;
  final DateTime end;

  const BudgetWindow({required this.start, required this.end});

  DateTime get lastIncludedDay => DateTime(end.year, end.month, end.day - 1);

  String get label {
    final formatted = DateFormat('MMMM yyyy', 'fr_FR').format(lastIncludedDay);
    return formatted[0].toUpperCase() + formatted.substring(1);
  }

  bool contains(DateTime day) => !day.isBefore(start) && day.isBefore(end);
}

/// The budget window containing [reference], starting on [startDay] of
/// whichever month that window begins in.
BudgetWindow budgetWindowContaining(DateTime reference, int startDay) {
  final ref = DateTime(reference.year, reference.month, reference.day);
  var start = _clampedDay(ref.year, ref.month, startDay);
  if (ref.isBefore(start)) {
    start = _clampedDay(ref.year, ref.month - 1, startDay);
  }
  final end = _clampedDay(start.year, start.month + 1, startDay);
  return BudgetWindow(start: start, end: end);
}

BudgetWindow previousBudgetWindow(BudgetWindow window, int startDay) =>
    budgetWindowContaining(DateTime(window.start.year, window.start.month, window.start.day - 1), startDay);

BudgetWindow nextBudgetWindow(BudgetWindow window, int startDay) =>
    budgetWindowContaining(window.end, startDay);
