// Throttled notification mixin — prevents excessive UI rebuilds during streaming.
//
// Both [CloudAgentService] and [LocalAgentService] stream tokens in real-time.
// Without throttling, each token triggers a full widget rebuild, causing jank.
// This mixin batches notifications into 50ms windows so the UI stays smooth.
//
// BUG-008 fix: Timer is properly cancelled in cancelThrottledNotifications()
// and the timer callback checks if the mixin is still active before notifying.
//
// Usage:
// ```dart
// class MyService extends ChangeNotifier with ThrottledNotifications {
//   void onToken(String token) {
//     // ... update state ...
//     throttledNotifyListeners();  // batches automatically
//   }
//
//   void onDone() {
//     flushNotifyListeners();  // force immediate notification
//   }
// }
// ```

import 'dart:async';
import 'package:flutter/foundation.dart';

mixin ThrottledNotifications on ChangeNotifier {
  Timer? _throttleTimer;
  bool _hasPendingNotification = false;
  bool _isDisposed = false;
  static const _throttleDuration = Duration(milliseconds: 50);

  /// Notify listeners, but batch rapid calls into 50ms windows.
  ///
  /// If a notification is already pending, this call is absorbed. The pending
  /// notification fires at the end of the current window, ensuring the UI
  /// always gets the latest state without per-frame rebuilds.
  void throttledNotifyListeners() {
    if (_isDisposed) return;
    if (_throttleTimer?.isActive ?? false) {
      _hasPendingNotification = true;
      return;
    }
    notifyListeners();
    _throttleTimer = Timer(_throttleDuration, () {
      // BUG-008 fix: Check if disposed before calling notifyListeners
      if (_isDisposed) return;
      if (_hasPendingNotification) {
        _hasPendingNotification = false;
        notifyListeners();
      }
    });
  }

  /// Force an immediate notification, bypassing the throttle.
  ///
  /// Use this for state changes that must be reflected instantly (e.g. state
  /// transitions from "thinking" to "connected", error messages, or final
  /// stream results).
  void flushNotifyListeners() {
    _throttleTimer?.cancel();
    _hasPendingNotification = false;
    if (_isDisposed) return;
    notifyListeners();
  }

  /// Cancel any pending throttled notifications.
  ///
  /// Call this in [dispose] to prevent notifications after the object is
  /// garbage-collected. BUG-008 fix: Also marks the mixin as disposed
  /// so the timer callback won't fire on a disposed ChangeNotifier.
  void cancelThrottledNotifications() {
    _isDisposed = true;
    _throttleTimer?.cancel();
    _hasPendingNotification = false;
  }
}
