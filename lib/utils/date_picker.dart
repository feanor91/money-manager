import 'package:flutter/material.dart';

/// Same call shape as [showDatePicker], but confirms as soon as a day is
/// tapped instead of requiring a separate "OK" press - every date picker
/// in this app is a quick single-value edit (a transaction's date, a
/// recurring bill's next occurrence, ...), so the extra confirmation step
/// is just friction with no benefit.
Future<DateTime?> pickDate({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 320,
        height: 460,
        child: Column(
          children: [
            if (helpText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(helpText, style: Theme.of(context).textTheme.labelLarge),
                ),
              ),
            Expanded(
              child: CalendarDatePicker(
                initialDate: initialDate,
                firstDate: firstDate,
                lastDate: lastDate,
                onDateChanged: (date) => Navigator.of(context).pop(date),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
