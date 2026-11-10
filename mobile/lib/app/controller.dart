import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/history.dart';
import '../core/oui.dart';
import '../net/scanner.dart';
import 'multicast_lock.dart';

const _kHistory = 'history.v1';
const _kFppOnly = 'ui.fppOnly';
const _kPinFpp = 'ui.pinFpp';
const _kShowOffline = 'ui.showOffline';
const _kInterval = 'ui.intervalSec';

/// Holds scan state + UI preferences for the whole app.
class ScanController extends ChangeNotifier {
  ScanController(this._prefs, this.state, this.oui) {
    fppOnly = _prefs.getBool(_kFppOnly) ?? false;
    pinFpp = _prefs.getBool(_kPinFpp) ?? true;
    showOffline = _prefs.getBool(_kShowOffline) ?? true;
    intervalSec = _prefs.getInt(_kInterval) ?? 60;
    // Show what we remembered while the first scan runs.
    final now = DateTime.now().millisecondsSinceEpoch;
    devices = state.devices.values
        .where((d) => now - d.lastSeen <= offlineRetainMs)
        .map((d) {
      d.online = false;
      d.isNew = false;
      d.confidence = 'offline';
      return d;
    }).toList();
  }

  static Future<ScanController> load() async {
    final prefs = await SharedPreferences.getInstance();
    HistoryState state = HistoryState();
    try {
      final raw = prefs.getString(_kHistory);
      if (raw != null) state = HistoryState.fromJson(jsonDecode(raw));
    } catch (_) {}
    OuiTable oui = OuiTable.empty;
    try {
      oui = OuiTable.fromJsonString(
          await rootBundle.loadString('assets/oui-data.json'));
    } catch (_) {}
    return ScanController(prefs, state, oui);
  }

  final SharedPreferences _prefs;
  final HistoryState state;
  final OuiTable oui;

  List<Device> devices = [];
  ScanResult? last;
  bool scanning = false;
  ScanProgress? progress;
  String? error;
  String query = '';

  bool fppOnly = false;
  bool pinFpp = true;
  bool showOffline = true;
  int intervalSec = 60;

  Timer? _timer;
  bool _foreground = true;

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    error = null;
    progress = null;
    notifyListeners();
    try {
      await MulticastLock.acquire();
      final scanner = Scanner(
        state: state,
        oui: oui,
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
      );
      final result = await scanner.scan();
      last = result;
      devices = result.devices;
      await _persist();
    } catch (e) {
      error = e.toString();
    } finally {
      await MulticastLock.release();
      scanning = false;
      progress = null;
      notifyListeners();
      _schedule();
    }
  }

  Future<void> _persist() async {
    try {
      await _prefs.setString(_kHistory, jsonEncode(state.toJson()));
    } catch (_) {/* history is a convenience; never fail a scan over it */}
  }

  /// Devices after filter / sort preferences.
  List<Device> get visible {
    final q = query.trim().toLowerCase();
    final list = devices.where((d) {
      if (fppOnly && !d.isFpp) return false;
      if (!showOffline && !d.online) return false;
      if (q.isEmpty) return true;
      final hay = [
        d.ip,
        d.hostname,
        d.mac,
        d.vendor,
        d.fpp?.version,
        d.fpp?.mode,
        d.fpp?.platform,
        d.fpp?.hostname,
        ...?d.fpp?.plugins,
      ].whereType<String>().join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
    return sortDevices(list, pinFpp: pinFpp);
  }

  int get fppCount => devices.where((d) => d.isFpp && d.online).length;

  void setQuery(String v) {
    query = v;
    notifyListeners();
  }

  void setFppOnly(bool v) {
    fppOnly = v;
    _prefs.setBool(_kFppOnly, v);
    notifyListeners();
  }

  void setPinFpp(bool v) {
    pinFpp = v;
    _prefs.setBool(_kPinFpp, v);
    notifyListeners();
  }

  void setShowOffline(bool v) {
    showOffline = v;
    _prefs.setBool(_kShowOffline, v);
    notifyListeners();
  }

  void setInterval(int sec) {
    intervalSec = sec;
    _prefs.setInt(_kInterval, sec);
    _schedule();
    notifyListeners();
  }

  /// Auto-rescan pauses while the app is in the background.
  void setForeground(bool fg) {
    _foreground = fg;
    if (fg) {
      if (!scanning && _timer == null) _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (intervalSec <= 0 || !_foreground) return;
    _timer = Timer(Duration(seconds: intervalSec), () {
      _timer = null;
      scan();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
