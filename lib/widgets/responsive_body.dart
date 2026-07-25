import 'package:flutter/material.dart';

/// Caps content width and centers it on wide screens (desktop browser
/// windows, tablets in landscape) so lists and cards don't stretch into
/// absurdly long thin rows - purely cosmetic, has no effect below
/// [maxWidth].
class ResponsiveBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ResponsiveBody({super.key, required this.child, this.maxWidth = 900});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
