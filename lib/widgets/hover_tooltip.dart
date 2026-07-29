import 'package:flutter/material.dart';

/// A tooltip that follows the mouse cursor instead of Flutter's built-in
/// [Tooltip] (which anchors to the widget it wraps, above or below it) -
/// used wherever hovering a row should pop up a short note (e.g. the
/// transactions contributing to a budget figure) right where the pointer
/// actually is.
class HoverTooltip extends StatefulWidget {
  final String message;
  final Widget child;

  const HoverTooltip({super.key, required this.message, required this.child});

  @override
  State<HoverTooltip> createState() => _HoverTooltipState();
}

class _HoverTooltipState extends State<HoverTooltip> {
  OverlayEntry? _entry;
  Offset _position = Offset.zero;

  void _show(Offset globalPosition) {
    _position = globalPosition;
    _entry = OverlayEntry(builder: (context) => _buildOverlay(context));
    Overlay.of(context).insert(_entry!);
  }

  void _move(Offset globalPosition) {
    _position = globalPosition;
    _entry?.markNeedsBuild();
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  Widget _buildOverlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: _position.dx + 16,
      top: _position.dy + 16,
      child: IgnorePointer(
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.inverseSurface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.message,
              style: TextStyle(fontSize: 12, color: scheme.onInverseSurface),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) => _show(event.position),
      onHover: (event) => _move(event.position),
      onExit: (_) => _hide(),
      child: widget.child,
    );
  }
}
