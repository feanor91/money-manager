import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A light blue used for the "forecast" segment - a known-but-not-yet-paid
/// recurring bill still folded into an "auto" envelope's target (see
/// budget_screen.dart's `_CategoryBarRow.forecastExtra`). Deliberately not
/// theme/palette-derived: it needs to read as a distinct third state next
/// to the green/amber/red actual-spend colours (also fixed, not
/// palette-derived - see AppTheme.positive/negative/warning) regardless of
/// which accent palette is selected.
const Color forecastColor = Color(0xFF64B5F6);

/// Animates a pulsing red glow around [child] - used for an over-budget
/// category, so it reads as "needs attention" at a glance, not just by its
/// (smaller, easy-to-miss) colour change alone. [borderRadius] should
/// match the wrapped child's own corner radius so the glow hugs its shape.
class PulsingHalo extends StatefulWidget {
  final Widget child;
  final double borderRadius;

  const PulsingHalo({super.key, required this.child, this.borderRadius = 14});

  @override
  State<PulsingHalo> createState() => _PulsingHaloState();
}

class _PulsingHaloState extends State<PulsingHalo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 550))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: [
              BoxShadow(
                color: AppTheme.negative.withValues(alpha: 0.25 + t * 0.55),
                blurRadius: 2 + t * 14,
                spreadRadius: 1 + t * 5,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
