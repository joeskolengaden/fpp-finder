import 'dart:io';

import 'package:flutter/services.dart';

/// Android drops inbound multicast packets (mDNS answers) unless the app holds
/// a WifiManager.MulticastLock. Implemented in MainActivity.kt. No-op on iOS.
class MulticastLock {
  static const _ch = MethodChannel('dev.fppfinder/multicast');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('acquire');
    } catch (_) {/* mDNS may find nothing; the TCP sweep still works */}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('release');
    } catch (_) {}
  }
}
