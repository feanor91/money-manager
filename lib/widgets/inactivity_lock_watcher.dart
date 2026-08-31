import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:provider/provider.dart';

import '../state/pin_lock_provider.dart';

/// Wraps the unlocked app content and auto-locks back to the PIN screen
/// after [PinLockProvider.autoLockDuration] of no pointer/keyboard activity
/// anywhere in the app - a second line of defense on top of
/// [PinLockProvider]'s existing background-grace-period lock
/// (app.dart's `didChangeAppLifecycleState`), which only fires once the app
/// is actually backgrounded and therefore never on web (a browser tab left
/// open and unattended never technically "backgrounds"). User-requested
/// 2026-08-31 ("timeout... configurable... 5mn par défaut").
///
/// Deliberately mounted only while [PinGateStatus.unlocked] (see
/// app.dart's `_GateContent`) - no point tracking idle time once already
/// locked, and remounting fresh on every unlock naturally starts a clean
/// timer rather than needing to reset one across gate transitions.
class InactivityLockWatcher extends StatefulWidget {
  final Widget child;

  const InactivityLockWatcher({super.key, required this.child});

  @override
  State<InactivityLockWatcher> createState() => _InactivityLockWatcherState();
}

class _InactivityLockWatcherState extends State<InactivityLockWatcher> {
  Timer? _timer;
  DateTime? _lastReset;

  @override
  void initState() {
    super.initState();
    // Pointer activity is caught by the Listener in build() (wraps the
    // whole app), but a keystroke with no accompanying pointer movement
    // (Tab navigation, typing without touching the mouse/trackpad) wouldn't
    // otherwise reach anything - a hardware-level handler catches those
    // regardless of which widget currently has focus.
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _resetTimer();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _timer?.cancel();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _resetTimer();
    return false; // passive observation only - never consume the event
  }

  /// Throttled to at most once/second - `onPointerMove`/hover fire
  /// continuously during an ordinary scroll or drag, and cancelling +
  /// recreating a [Timer] on every single one of those would be wasted
  /// churn for no real accuracy gain (a 1s slop on a multi-minute timeout
  /// is imperceptible).
  void _resetTimer() {
    final now = DateTime.now();
    if (_lastReset != null && now.difference(_lastReset!) < const Duration(seconds: 1)) {
      return;
    }
    _lastReset = now;
    _timer?.cancel();
    final duration = context.read<PinLockProvider>().autoLockDuration;
    _timer = Timer(duration, () {
      if (mounted) context.read<PinLockProvider>().lockNow();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetTimer(),
      onPointerMove: (_) => _resetTimer(),
      onPointerSignal: (_) => _resetTimer(),
      onPointerHover: (_) => _resetTimer(),
      child: widget.child,
    );
  }
}
