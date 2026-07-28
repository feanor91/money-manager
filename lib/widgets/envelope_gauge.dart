import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A light blue used for the "forecast" segment - a known-but-not-yet-paid
/// recurring bill still folded into an "auto" envelope's target (see
/// [EnvelopeGauge.forecastExtra]). Deliberately not theme/palette-derived:
/// it needs to read as a distinct third state next to the green/amber/red
/// actual-spend colours (also fixed, not palette-derived - see
/// AppTheme.positive/negative/warning) regardless of which accent palette
/// is selected.
const Color forecastColor = Color(0xFF64B5F6);

/// A vertical "thermometer" gauge for one budget envelope: fills from the
/// bottom as [spent] approaches [target]. An optional [forecastExtra] on
/// top of that (in light blue) represents a known recurring bill that
/// hasn't actually posted yet this period - without it, an "auto" envelope
/// for a bill due later in the month looks empty/unplanned even though its
/// target already accounts for it. Over target, the fill caps at the top
/// and turns red with a pulsing halo + a small overage badge floating
/// above (positioned absolutely so it never shifts the gauge itself out
/// of alignment with its neighbours - see EnvelopeGaugeRow).
class EnvelopeGauge extends StatelessWidget {
  static const double width = 28;
  static const double height = 110;

  final double spent;
  final double target;
  final double forecastExtra;
  final bool selected;
  final VoidCallback? onTap;

  const EnvelopeGauge({
    super.key,
    required this.spent,
    required this.target,
    this.forecastExtra = 0,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = target > 0 ? spent / target : (spent > 0 ? 2.0 : 0.0);
    final over = ratio > 1;
    final fillRatio = ratio.clamp(0, 1).toDouble();
    final forecastRatio =
        target > 0 && !over ? ((spent + forecastExtra) / target).clamp(0, 1).toDouble() : fillRatio;
    final color = over
        ? AppTheme.negative
        : (ratio >= 0.8 ? AppTheme.warning : AppTheme.positive);
    final scheme = Theme.of(context).colorScheme;

    Widget gauge = Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? scheme.onSurface
              : (over ? AppTheme.negative : scheme.outlineVariant),
          width: selected ? 2 : (over ? 1.5 : 0.5),
        ),
      ),
      child: Stack(
        children: [
          if (forecastRatio > fillRatio)
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: forecastRatio,
                widthFactor: 1,
                child: Container(color: forecastColor.withValues(alpha: 0.45)),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: fillRatio,
              widthFactor: 1,
              child: Container(color: color),
            ),
          ),
        ],
      ),
    );

    if (over) gauge = _PulsingHalo(child: gauge);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            gauge,
            if (over)
              Positioned(
                top: -18,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppTheme.negative.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '+${(spent - target).toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.negative,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Animates a pulsing red glow around [child] - used for an over-budget
/// envelope, so it reads as "needs attention" even in a quick glance at a
/// long horizontal row of gauges, not just by its (smaller, easy-to-miss)
/// colour change alone.
class _PulsingHalo extends StatefulWidget {
  final Widget child;

  const _PulsingHalo({required this.child});

  @override
  State<_PulsingHalo> createState() => _PulsingHaloState();
}

class _PulsingHaloState extends State<_PulsingHalo> with SingleTickerProviderStateMixin {
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
            borderRadius: BorderRadius.circular(14),
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
