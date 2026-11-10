import 'fpp.dart';
import 'oui.dart';
import 'subnet.dart';

// Device model + first-seen / last-seen history. Pure (no I/O): the scanner
// feeds raw per-host findings in, gets the merged device list back, and the
// app layer persists HistoryState.toJson() wherever it likes.

const int retainMs = 30 * 24 * 3600 * 1000; // history kept for 30 days
const int offlineRetainMs = 7 * 24 * 3600 * 1000; // offline rows shown for 7 days

class OpenPort {
  const OpenPort(this.port, this.name);
  final int port;
  final String name;
  Map<String, dynamic> toJson() => {'port': port, 'name': name};
  factory OpenPort.fromJson(Map<String, dynamic> j) =>
      OpenPort(j['port'] as int, (j['name'] as String?) ?? '');
}

class ServiceRef {
  const ServiceRef(this.type, this.port);
  final String? type;
  final int? port;
  Map<String, dynamic> toJson() => {'type': type, 'port': port};
  factory ServiceRef.fromJson(Map<String, dynamic> j) =>
      ServiceRef(j['type'] as String?, j['port'] as int?);
}

/// What mDNS/Bonjour told us about one IP.
class MdnsHit {
  MdnsHit();
  final Set<String> hostnames = {};
  final List<ServiceRef> services = [];
}

/// Raw findings for one live host during a scan (before history merge).
class ScanHost {
  ScanHost(this.ip);
  final String ip;
  final Set<String> via = {};
  bool alive = false;
  List<OpenPort> ports = [];
  MdnsHit? mdns;
  FppInfo? fpp;
  String? dnsName; // reverse DNS
  String? resolvedName; // e.g. fpp.local
  String? ifaceName;
  String? network;
}

class Device {
  Device({
    required this.key,
    required this.ip,
    this.mac,
    this.macSource,
    this.hostname,
    this.hostnameSource,
    this.vendor,
    this.ports = const [],
    this.services = const [],
    this.fpp,
    this.iface,
    this.network,
    this.via = const [],
    required this.firstSeen,
    required this.lastSeen,
    this.lastFpp,
    this.online = false,
    this.isNew = false,
    this.confidence = 'offline',
  });

  final String key;
  final String ip;
  final String? mac;
  final String? macSource;
  final String? hostname;
  final String? hostnameSource;
  final String? vendor;
  final List<OpenPort> ports;
  final List<ServiceRef> services;
  final FppInfo? fpp;
  final String? iface;
  final String? network;
  final List<String> via;
  final int firstSeen;
  final int lastSeen;
  final int? lastFpp;

  // runtime-only (not persisted)
  bool online;
  bool isNew;
  String confidence;

  bool get isFpp => fpp != null;

  Map<String, dynamic> toJson() => {
        'key': key,
        'ip': ip,
        'mac': mac,
        'macSource': macSource,
        'hostname': hostname,
        'hostnameSource': hostnameSource,
        'vendor': vendor,
        'ports': ports.map((p) => p.toJson()).toList(),
        'services': services.map((s) => s.toJson()).toList(),
        'fpp': fpp?.toJson(),
        'iface': iface,
        'network': network,
        'via': via,
        'firstSeen': firstSeen,
        'lastSeen': lastSeen,
        'lastFpp': lastFpp,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        key: j['key'] as String,
        ip: j['ip'] as String,
        mac: j['mac'] as String?,
        macSource: j['macSource'] as String?,
        hostname: j['hostname'] as String?,
        hostnameSource: j['hostnameSource'] as String?,
        vendor: j['vendor'] as String?,
        ports: (j['ports'] as List? ?? const [])
            .map((p) => OpenPort.fromJson((p as Map).cast<String, dynamic>()))
            .toList(),
        services: (j['services'] as List? ?? const [])
            .map((p) => ServiceRef.fromJson((p as Map).cast<String, dynamic>()))
            .toList(),
        fpp: j['fpp'] == null
            ? null
            : FppInfo.fromJson((j['fpp'] as Map).cast<String, dynamic>()),
        iface: j['iface'] as String?,
        network: j['network'] as String?,
        via: (j['via'] as List? ?? const []).cast<String>(),
        firstSeen: j['firstSeen'] as int,
        lastSeen: j['lastSeen'] as int,
        lastFpp: j['lastFpp'] as int?,
      );
}

class ScanSpan {
  const ScanSpan(this.started, this.ended);
  final int started;
  final int ended;
}

class HistoryState {
  HistoryState({Map<String, Device>? devices, this.lastScan})
      : devices = devices ?? {};
  final Map<String, Device> devices;
  ScanSpan? lastScan;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'devices': devices.map((k, v) => MapEntry(k, v.toJson())),
        'lastScan': lastScan == null
            ? null
            : {'started': lastScan!.started, 'ended': lastScan!.ended},
      };

  /// Tolerant loader: anything unreadable yields an empty history.
  static HistoryState fromJson(Object? j) {
    try {
      if (j is Map && j['version'] == 1 && j['devices'] is Map) {
        final devices = <String, Device>{};
        (j['devices'] as Map).forEach((k, v) {
          try {
            devices[k as String] =
                Device.fromJson((v as Map).cast<String, dynamic>());
          } catch (_) {/* skip a corrupt row */}
        });
        final ls = j['lastScan'];
        return HistoryState(
          devices: devices,
          lastScan: ls is Map
              ? ScanSpan(ls['started'] as int, ls['ended'] as int)
              : null,
        );
      }
    } catch (_) {}
    return HistoryState();
  }

  void prune(int now) {
    devices.removeWhere((_, d) => now - d.lastSeen > retainMs);
  }
}

class BestName {
  const BestName(this.name, this.source);
  final String name;
  final String source;
}

BestName? bestName(ScanHost h) {
  final f = h.fpp;
  if (f != null && f.hostname != null) return BestName(f.hostname!, 'fpp');
  final m = h.mdns;
  if (m != null && m.hostnames.isNotEmpty) {
    final n = m.hostnames.firstWhere((x) => x.endsWith('.local'),
        orElse: () => m.hostnames.first);
    return BestName(n, 'mdns');
  }
  if (h.resolvedName != null && h.alive) {
    return BestName(h.resolvedName!, 'dns-local');
  }
  if (h.dnsName != null) return BestName(h.dnsName!, 'dns');
  return null;
}

class ScanResult {
  ScanResult({
    required this.started,
    required this.ended,
    required this.interfaces,
    required this.devices,
    required this.firstRun,
    this.warnings = const [],
  });
  final int started;
  final int ended;
  final List<Iface> interfaces;
  final List<Device> devices;
  final bool firstRun;
  final List<String> warnings;
}

/// Merges one scan's findings into [state] (mutating it) and returns the full
/// device list: live devices from this scan plus recently-seen offline ones.
ScanResult mergeScan(
  HistoryState state,
  List<ScanHost> hosts, {
  required int started,
  required int now,
  required List<Iface> interfaces,
  OuiTable? oui,
}) {
  final table = oui ?? OuiTable.empty;
  final prevScan = state.lastScan;
  final baseline = prevScan != null; // very first scan: nothing is flagged NEW
  final devices = state.devices;
  final seenKeys = <String>{};

  for (final h in hosts) {
    // Phones cannot read the ARP table; the only MAC source is the FPP
    // device itself (/api/network/interface lists its own MAC per address).
    String? mac;
    String? macSource;
    final f = h.fpp;
    if (f != null) {
      for (final i in f.interfaces) {
        if (i.addrs.contains(h.ip) && normalizeMac(i.mac) != null) {
          mac = normalizeMac(i.mac);
          macSource = 'fpp';
          break;
        }
      }
    }
    final key = mac ?? 'ip:${h.ip}';
    seenKeys.add(key);
    final nm = bestName(h);
    final prev = devices[key];
    final legacy = mac != null ? devices['ip:${h.ip}'] : null;
    final first = prev?.firstSeen ?? legacy?.firstSeen ?? now;
    if (legacy != null) devices.remove('ip:${h.ip}');
    FppInfo? fppKept = h.fpp;
    if (fppKept == null &&
        h.alive &&
        prev?.fpp != null &&
        h.ports.isEmpty) {
      fppKept = prev!.fpp; // alive but silent this time: keep the last verdict
    }
    devices[key] = Device(
      key: key,
      ip: h.ip,
      mac: mac,
      macSource: macSource,
      hostname: nm?.name ?? prev?.hostname,
      hostnameSource: nm?.source,
      vendor: mac != null ? table.lookupVendor(mac) : null,
      ports: h.ports,
      services: h.mdns?.services ?? const [],
      fpp: fppKept,
      iface: h.ifaceName,
      network: h.network,
      via: h.via.toList(),
      firstSeen: first,
      lastSeen: now,
      lastFpp: h.fpp != null ? now : prev?.lastFpp,
    );
  }
  state.lastScan = ScanSpan(started, now);
  state.prune(now);

  final out = <Device>[];
  for (final d in devices.values) {
    final online = seenKeys.contains(d.key);
    if (!online && now - d.lastSeen > offlineRetainMs) continue;
    d.online = online;
    // NEW = first appeared during this scan (and this is not the very first scan).
    d.isNew = online && baseline && d.firstSeen >= started;
    d.confidence = !online
        ? 'offline'
        : (d.via.contains('tcp') || d.via.contains('mdns'))
            ? 'live'
            : 'unconfirmed';
    out.add(d);
  }
  sortDevices(out);
  return ScanResult(
    started: started,
    ended: now,
    interfaces: interfaces,
    devices: out,
    firstRun: !baseline,
  );
}

/// Default order: online first, then most recently seen, then newest
/// first-seen, then by IP. With [pinFpp], FPP devices go to the top.
List<Device> sortDevices(List<Device> list, {bool pinFpp = false}) {
  list.sort((a, b) {
    if (pinFpp && a.isFpp != b.isFpp) return a.isFpp ? -1 : 1;
    if (a.online != b.online) return a.online ? -1 : 1;
    if (b.lastSeen != a.lastSeen) return b.lastSeen.compareTo(a.lastSeen);
    if (b.firstSeen != a.firstSeen) return b.firstSeen.compareTo(a.firstSeen);
    return (ipToInt(a.ip) ?? 0).compareTo(ipToInt(b.ip) ?? 0);
  });
  return list;
}
