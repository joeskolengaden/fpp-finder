import 'dart:convert';

// FPP (Falcon Player) detection. Everything here is pure: classify*() turn the
// body of a read-only GET into structured data. Port of src/core/fpp.js.

/// Decodes [body] as JSON. FPP 5.x's PHP can print "<b>Notice</b>: ..." HTML
/// before the JSON payload, so on failure we skip ahead to the first { or [.
dynamic safeJson(Object? body) {
  if (body is Map || body is List) return body;
  final text = body == null ? '' : body.toString();
  try {
    return jsonDecode(text);
  } catch (_) {}
  final m = RegExp(r'[\[{]').firstMatch(text);
  if (m != null && m.start > 0) {
    try {
      return jsonDecode(text.substring(m.start));
    } catch (_) {}
  }
  return null;
}

String? _s(Object? v) => v?.toString();
int? _i(Object? v) => v == null ? null : int.tryParse(v.toString());

class VersionInfo {
  const VersionInfo(
      {required this.isFpp, this.version, this.branch, this.major, this.minor});
  final bool isFpp;
  final String? version;
  final String? branch;
  final int? major;
  final int? minor;
}

/// GET /api/fppd/version
///   {"fppdAPI":"v1","version":"5.4.1","branch":"v5.4","majorVersion":"5",...}
VersionInfo classifyVersion(Object? body) {
  final j = safeJson(body);
  if (j is! Map) return const VersionInfo(isFpp: false);
  final hasApi = j['fppdAPI'] is String;
  final hasVer = j['version'] is String &&
      (j.containsKey('branch') || j.containsKey('majorVersion'));
  if (!hasApi && !hasVer) return const VersionInfo(isFpp: false);
  return VersionInfo(
    isFpp: true,
    version: _s(j['version']),
    branch: _s(j['branch']),
    major: _i(j['majorVersion']),
    minor: _i(j['minorVersion']),
  );
}

const _modeNum = {1: 'bridge', 2: 'player', 6: 'player', 8: 'remote'};

class StatusInfo {
  const StatusInfo({
    this.fppd,
    this.mode,
    this.bridging = false,
    this.multisync = false,
    this.status,
    this.uptime,
    this.playlist,
    this.sequence,
  });
  final String? fppd;
  final String? mode;
  final bool bridging;
  final bool multisync;
  final String? status;
  final String? uptime;
  final String? playlist;
  final String? sequence;
}

bool _truthy(Object? v) => v == true || v == 1;
String? _nonEmpty(Object? v) {
  final s = _s(v);
  return (s == null || s.isEmpty) ? null : s;
}

/// GET /api/fppd/status
StatusInfo? classifyStatus(Object? body) {
  final j = safeJson(body);
  if (j is! Map) return null;
  String? mode =
      (j['mode_name'] is String && (j['mode_name'] as String).isNotEmpty)
          ? j['mode_name'] as String
          : _modeNum[j['mode']];
  if (mode == 'master') mode = 'player';
  final cp = j['current_playlist'];
  return StatusInfo(
    fppd: _nonEmpty(j['fppd']),
    mode: mode,
    bridging: _truthy(j['bridging']),
    multisync: _truthy(j['multisync']),
    status: _nonEmpty(j['status_name']),
    uptime: _nonEmpty(j['uptime']),
    playlist: cp is Map ? _nonEmpty(cp['playlist']) : null,
    sequence: _nonEmpty(j['current_sequence']),
  );
}

String? platformFamily(String? text) {
  final s = text ?? '';
  if (RegExp(r'beagle|am33|bbb|bbg|pocketbeagle|\bti\b', caseSensitive: false)
      .hasMatch(s)) {
    return 'BeagleBone';
  }
  if (RegExp(r'raspberry|\brpi\b|\bpi ?(zero|[0-9])|bcm2', caseSensitive: false)
      .hasMatch(s)) {
    return 'Raspberry Pi';
  }
  if (RegExp(r'docker|container', caseSensitive: false).hasMatch(s)) {
    return 'Docker';
  }
  if (RegExp(r'linux|debian|ubuntu|x86|amd64', caseSensitive: false)
      .hasMatch(s)) {
    return 'Linux';
  }
  if (RegExp(r'mac|darwin', caseSensitive: false).hasMatch(s)) {
    return 'macOS';
  }
  return s.isEmpty ? null : s;
}

class Peer {
  const Peer({required this.address, this.hostname, this.version, this.type});
  final String address;
  final String? hostname;
  final String? version;
  final String? type;

  Map<String, dynamic> toJson() => {
        'address': address,
        'hostname': hostname,
        'version': version,
        'type': type,
      };
  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
      address: j['address'] as String,
      hostname: j['hostname'] as String?,
      version: j['version'] as String?,
      type: j['type'] as String?);
}

class MultiSyncInfo {
  const MultiSyncInfo({
    this.hostname,
    this.model,
    this.type,
    this.version,
    this.mode,
    this.platform,
    this.peers = const [],
  });
  final String? hostname;
  final String? model;
  final String? type;
  final String? version;
  final String? mode;
  final String? platform;
  final List<Peer> peers;
}

/// GET /api/fppd/multiSyncSystems
///   {systems:[{address,hostname,model,type,version,local:1,fppModeString}]}
MultiSyncInfo? classifyMultiSync(Object? body, String ip) {
  final j = safeJson(body);
  if (j is! Map || j['systems'] is! List) return null;
  final systems = (j['systems'] as List).whereType<Map>().toList();
  Map? sys;
  for (final s in systems) {
    if (_truthy(s['local'])) {
      sys = s;
      break;
    }
  }
  sys ??= systems.cast<Map?>().firstWhere((s) => s!['address'] == ip,
      orElse: () => null);
  if (sys == null) return null;
  final self = sys;
  return MultiSyncInfo(
    hostname: _nonEmpty(self['hostname']),
    model: _nonEmpty(self['model']),
    type: _nonEmpty(self['type']),
    version: _nonEmpty(self['version']),
    mode: _nonEmpty(self['fppModeString']),
    platform: platformFamily('${self['model'] ?? ''} ${self['type'] ?? ''}'),
    peers: systems
        .where((s) => !identical(s, self) && s['address'] != null)
        .map((s) => Peer(
              address: s['address'].toString(),
              hostname: _nonEmpty(s['hostname']),
              version: _nonEmpty(s['version']),
              type: _nonEmpty(s['type']),
            ))
        .toList(),
  );
}

class SysInfo {
  const SysInfo(
      {this.hostname,
      this.description,
      this.platform,
      this.model,
      this.osVersion,
      this.version,
      this.mode});
  final String? hostname;
  final String? description;
  final String? platform;
  final String? model;
  final String? osVersion;
  final String? version;
  final String? mode;
}

/// GET /api/system/info  (newer FPP only; a 404 page on 5.4)
SysInfo? classifySystemInfo(Object? body) {
  final j = safeJson(body);
  if (j is! Map) return null;
  if (_nonEmpty(j['Platform']) == null &&
      _nonEmpty(j['HostName']) == null &&
      _nonEmpty(j['Variant']) == null) {
    return null;
  }
  return SysInfo(
    hostname: _nonEmpty(j['HostName']),
    description: _nonEmpty(j['HostDescription']),
    platform: platformFamily('${j['Platform'] ?? ''} ${j['Variant'] ?? ''}'),
    model: _nonEmpty(j['Variant']) ?? _nonEmpty(j['Platform']),
    osVersion: _nonEmpty(j['OSVersion']),
    version: _nonEmpty(j['Version']),
    mode: _nonEmpty(j['Mode']),
  );
}

/// GET /api/plugin -> ["a","b"] (5.4) or [{"name":..}] in other versions
List<String> classifyPlugins(Object? body) {
  final j = safeJson(body);
  if (j is! List) return [];
  final out = <String>[];
  for (final p in j) {
    String? n;
    if (p is String) {
      n = p;
    } else if (p is Map) {
      n = _nonEmpty(p['name']) ?? _nonEmpty(p['repoName']) ?? _nonEmpty(p['id']);
    }
    if (n != null && n.isNotEmpty) out.add(n);
  }
  return out;
}

class NetIface {
  const NetIface(
      {required this.name, this.mac, this.state, this.addrs = const []});
  final String name;
  final String? mac;
  final String? state;
  final List<String> addrs;

  Map<String, dynamic> toJson() =>
      {'name': name, 'mac': mac, 'state': state, 'addrs': addrs};
  factory NetIface.fromJson(Map<String, dynamic> j) => NetIface(
      name: j['name'] as String,
      mac: j['mac'] as String?,
      state: j['state'] as String?,
      addrs: (j['addrs'] as List? ?? const []).cast<String>());
}

/// GET /api/network/interface -> [{ifname, address(MAC), addr_info:[{local}]}]
List<NetIface> classifyInterfaces(Object? body) {
  final j = safeJson(body);
  if (j is! List) return [];
  final out = <NetIface>[];
  for (final i in j) {
    if (i is! Map) continue;
    final name = _nonEmpty(i['ifname']);
    if (name == null || name == 'lo') continue;
    final addrs = <String>[];
    final ai = i['addr_info'];
    if (ai is List) {
      for (final a in ai) {
        if (a is Map && a['family'] == 'inet' && a['local'] != null) {
          addrs.add(a['local'].toString());
        }
      }
    }
    out.add(NetIface(
        name: name,
        mac: _nonEmpty(i['address']),
        state: _nonEmpty(i['operstate']),
        addrs: addrs));
  }
  return out;
}

/// Device-level FPP descriptor, merged from all probe responses.
class FppInfo {
  const FppInfo({
    required this.url,
    this.version,
    this.branch,
    this.mode,
    this.modeLabel,
    this.platform,
    this.model,
    this.hostname,
    this.description,
    this.fppd,
    this.state,
    this.uptime,
    this.playlist,
    this.sequence,
    this.multisync = false,
    this.plugins = const [],
    this.peers = const [],
    this.interfaces = const [],
  });

  final String url;
  final String? version;
  final String? branch;
  final String? mode;
  final String? modeLabel;
  final String? platform;
  final String? model;
  final String? hostname;
  final String? description;
  final String? fppd;
  final String? state;
  final String? uptime;
  final String? playlist;
  final String? sequence;
  final bool multisync;
  final List<String> plugins;
  final List<Peer> peers;
  final List<NetIface> interfaces;

  Map<String, dynamic> toJson() => {
        'url': url,
        'version': version,
        'branch': branch,
        'mode': mode,
        'modeLabel': modeLabel,
        'platform': platform,
        'model': model,
        'hostname': hostname,
        'description': description,
        'fppd': fppd,
        'state': state,
        'uptime': uptime,
        'playlist': playlist,
        'sequence': sequence,
        'multisync': multisync,
        'plugins': plugins,
        'peers': peers.map((p) => p.toJson()).toList(),
        'interfaces': interfaces.map((i) => i.toJson()).toList(),
      };

  factory FppInfo.fromJson(Map<String, dynamic> j) => FppInfo(
        url: j['url'] as String,
        version: j['version'] as String?,
        branch: j['branch'] as String?,
        mode: j['mode'] as String?,
        modeLabel: j['modeLabel'] as String?,
        platform: j['platform'] as String?,
        model: j['model'] as String?,
        hostname: j['hostname'] as String?,
        description: j['description'] as String?,
        fppd: j['fppd'] as String?,
        state: j['state'] as String?,
        uptime: j['uptime'] as String?,
        playlist: j['playlist'] as String?,
        sequence: j['sequence'] as String?,
        multisync: j['multisync'] == true,
        plugins: (j['plugins'] as List? ?? const []).cast<String>(),
        peers: (j['peers'] as List? ?? const [])
            .map((p) => Peer.fromJson((p as Map).cast<String, dynamic>()))
            .toList(),
        interfaces: (j['interfaces'] as List? ?? const [])
            .map((p) => NetIface.fromJson((p as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// Merges probe results. Returns null when [version] says "not FPP".
FppInfo? buildFppInfo({
  required String ip,
  required VersionInfo? version,
  StatusInfo? status,
  MultiSyncInfo? multisync,
  SysInfo? sysinfo,
  List<String>? plugins,
  List<NetIface>? interfaces,
}) {
  if (version == null || !version.isFpp) return null;
  final mode = status?.mode ?? multisync?.mode ?? sysinfo?.mode;
  final platform = multisync?.platform ?? sysinfo?.platform;
  return FppInfo(
    url: 'http://$ip/',
    version: version.version ?? multisync?.version,
    branch: version.branch,
    mode: mode,
    modeLabel: mode == null
        ? null
        : ((status?.bridging ?? false) && mode == 'player'
            ? 'player + bridge'
            : mode),
    platform: platform,
    model: multisync?.model ?? sysinfo?.model,
    hostname: multisync?.hostname ?? sysinfo?.hostname,
    description: sysinfo?.description,
    fppd: status?.fppd,
    state: status?.status,
    uptime: status?.uptime,
    playlist: status?.playlist,
    sequence: status?.sequence,
    multisync: status?.multisync ?? false,
    plugins: plugins ?? const [],
    peers: multisync?.peers ?? const [],
    interfaces: interfaces ?? const [],
  );
}
