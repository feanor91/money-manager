import 'package:flutter/material.dart';

/// A small floating pill (spinner only, no text) hovering near the top of
/// [child] when [refreshing] is true - visible feedback that new data is
/// loading in the background (after a write, or a manual refresh) without
/// erasing the screen the way a full-page spinner replacing [child] would
/// (found disagreeable 2026-09-10, see the `_lastData` retain-previous-data
/// pattern this pairs with). Purely additive - [child] itself never moves
/// or resizes when this appears/disappears.
///
/// A first version used a thin [LinearProgressIndicator] pinned flush to
/// the very top edge - since [child] here is usually a whole [Scaffold],
/// that line sat right on top of (and visually fought with) the AppBar
/// itself rather than reading as a separate, deliberate piece of chrome.
/// A small badge floating just below the top edge, faded in/out rather
/// than popping, reads as its own thing instead (2026-09-10, user
/// feedback: "la barre d'attente c'est bof").
class RefreshingOverlay extends StatelessWidget {
  final bool refreshing;
  final Widget child;

  const RefreshingOverlay({super.key, required this.refreshing, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        child,
        Positioned(
          top: 10,
          left: 0,
          right: 0,
          child: Center(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: refreshing ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: AnimatedScale(
                  scale: refreshing ? 1 : 0.8,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
