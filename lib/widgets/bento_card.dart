import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Base building block of the Bento dashboard: a rounded card with
/// consistent padding, an optional title row, that a grid arranges into
/// varying sizes.
class BentoCard extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const BentoCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      // Clips any content that overflows the card's own bounds (e.g. a
      // header row that needs more height than a fixed-height parent gives
      // it at a narrow width) instead of letting it silently paint past
      // the card and over whatever sits below it in the page.
      clipBehavior: Clip.antiAlias,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A responsive bento-style grid: wraps a staggered layout using a
/// [StaggeredBentoDelegate]-free approach (simple wrap-based grid that
/// adapts column count to width).
class BentoGrid extends StatelessWidget {
  final List<BentoTile> tiles;

  const BentoGrid({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 4
            : constraints.maxWidth >= 700
                ? 2
                : 1;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppTheme.gridGap,
            crossAxisSpacing: AppTheme.gridGap,
            mainAxisExtent: 220,
          ),
          itemCount: tiles.length,
          itemBuilder: (context, index) {
            final tile = tiles[index];
            return SizedBox(
              width: double.infinity,
              child: tile.child,
            );
          },
        );
      },
    );
  }
}

class BentoTile {
  final Widget child;
  final int span;

  const BentoTile({required this.child, this.span = 1});
}
