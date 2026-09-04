import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:provider/provider.dart';

import '../state/pin_lock_provider.dart';

/// Tracks how many dialog/bottom-sheet/popup-menu routes are open across the
/// whole app, via Flutter's own [PopupRoute] marker - covers `showDialog`,
/// `showModalBottomSheet`, `showMenu`, `showDatePicker`/`showTimePicker`
/// (built on `showDialog` internally) and anything else built the same way,
/// present and future, without needing every call site to opt in
/// individually. Register as one of [MaterialApp.navigatorObservers].
///
/// A top-level singleton rather than owned by [InactivityLockWatcher]
/// itself: the watcher is torn down and rebuilt fresh on every lock/unlock
/// cycle (see `_GateContent` in app.dart), but this needs to keep counting
/// across that - a dialog opened just before an auto-lock fires (or opened
/// while a PIN was only just re-entered) must still be recognized as open.
final dialogActivityObserver = DialogActivityObserver();

class DialogActivityObserver extends NavigatorObserver with ChangeNotifier {
  int _openCount = 0;
  bool get hasOpenDialog => _openCount > 0;

  void _adjust(int delta) {
    final wasOpen = hasOpenDialog;
    _openCount = (_openCount + delta).clamp(0, 1 << 30);
    if (wasOpen != hasOpenDialog) notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    if (route is PopupRoute) _adjust(1);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PopupRoute) _adjust(-1);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is PopupRoute) _adjust(-1);
  }
}

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
///
/// The countdown pauses entirely while [dialogActivityObserver] reports any
/// dialog/bottom sheet/popup menu open (2026-09 user report: opening "Poser
/// une question" and reading a long AI answer, or just waiting on a slow
/// model, involves long stretches with no physical pointer/keyboard activity
/// at all - the countdown kept running underneath the dialog regardless, so
/// closing it could immediately drop back to the PIN screen). This is
/// generic to *every* dialog in the app, not special-cased to that one - see
/// [DialogActivityObserver]'s own doc comment.
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
    dialogActivityObserver.addListener(_onDialogActivityChanged);
    _resetTimer();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    dialogActivityObserver.removeListener(_onDialogActivityChanged);
    _timer?.cancel();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    _resetTimer();
    return false; // passive observation only - never consume the event
  }

  /// A dialog opening cancels the pending timer without starting a new one
  /// (see the `hasOpenDialog` check in [_resetTimer]) - genuinely paused,
  /// not just reset, so a very long time spent in a dialog never
  /// accumulates toward the lock. A dialog closing is itself treated as
  /// fresh activity, `force: true` so it restarts even if some unrelated
  /// pointer event happened to reset the timer (and its throttle window)
  /// moments earlier.
  void _onDialogActivityChanged() => _resetTimer(force: true);

  /// Throttled to at most once/second - `onPointerMove`/hover fire
  /// continuously during an ordinary scroll or drag, and cancelling +
  /// recreating a [Timer] on every single one of those would be wasted
  /// churn for no real accuracy gain (a 1s slop on a multi-minute timeout
  /// is imperceptible). [force] bypasses that throttle for the one caller
  /// ([_onDialogActivityChanged]) where always actually rescheduling matters
  /// more than the throttle's minor perf saving.
  void _resetTimer({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastReset != null &&
        now.difference(_lastReset!) < const Duration(seconds: 1)) {
      return;
    }
    _lastReset = now;
    _timer?.cancel();
    if (dialogActivityObserver.hasOpenDialog) return;
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
