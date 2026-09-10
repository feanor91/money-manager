import 'package:flutter/material.dart';

/// A thin indeterminate progress bar pinned to the very top of [child] when
/// [refreshing] is true - visible feedback that new data is loading in the
/// background (after a write, or a manual refresh) without erasing the
/// screen the way a full-page spinner replacing [child] would (found
/// disagreeable 2026-09-10, see the `_lastData` retain-previous-data
/// pattern this pairs with). Purely additive - [child] itself never moves
/// or resizes when this appears/disappears.
class RefreshingOverlay extends StatelessWidget {
  final bool refreshing;
  final Widget child;

  const RefreshingOverlay({super.key, required this.refreshing, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!refreshing) return child;
    return Stack(
      children: [
        child,
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: LinearProgressIndicator(minHeight: 3),
        ),
      ],
    );
  }
}
