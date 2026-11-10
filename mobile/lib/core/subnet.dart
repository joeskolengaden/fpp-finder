// Pure IPv4 helpers. No I/O. Port of src/core/subnet.js from the desktop app.

int? ipToInt(String ip) {
  final p = ip.trim().split('.');
  if (p.length != 4) return null;
  var n = 0;
  for (final s in p) {
    final v = int.tryParse(s);
    if (v == null || v < 0 || v > 255 || s.isEmpty) return null;
    n = (n << 8) | v;
  }
  return n & 0xffffffff;
}

String intToIp(int n) =>
    '${(n >> 24) & 255}.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}';

/// Number of leading one-bits, or null when the mask is not contiguous.
int? prefixFromNetmask(String mask) {
  final n = ipToInt(mask);
  if (n == null) return null;
  var bits = 0;
  var seenZero = false;
  for (var i = 31; i >= 0; i--) {
    if (((n >> i) & 1) == 1) {
      if (seenZero) return null;
      bits++;
    } else {
      seenZero = true;
    }
  }
  return bits;
}

int maskInt(int prefix) =>
    prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;

bool isLinkLocal(String ip) => ip.startsWith('169.254.');

bool isPrivateOrLinkLocal(String ip) => RegExp(
        r'^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)')
    .hasMatch(ip);

/// One of the phone's own IPv4 networks (Wi-Fi).
class Iface {
  Iface({
    required this.name,
    required this.ip,
    required this.netmask,
    required this.prefix,
    required this.network,
    required this.broadcast,
  });

  final String name;
  final String ip;
  final String netmask;
  final int prefix;
  final String network;
  final String broadcast;

  String get cidr => '$network/$prefix';
  bool get linkLocal => isLinkLocal(ip);
  int get hostCount => (1 << (32 - prefix)) - 2;

  /// Builds an interface from the phone's address + netmask. Returns null for
  /// unusable input (bad mask, loopback, 0.0.0.0, prefix outside /8../30).
  /// When [netmask] is null/invalid we assume the common home-LAN /24.
  static Iface? from(String name, String address, String? netmask) {
    final ipInt = ipToInt(address);
    if (ipInt == null) return null;
    if (address.startsWith('127.') || address.startsWith('0.')) return null;
    var prefix = netmask == null ? null : prefixFromNetmask(netmask);
    prefix ??= 24;
    if (prefix < 8 || prefix > 30) return null;
    final mask = maskInt(prefix);
    final net = ipInt & mask;
    final bcast = (net | (~mask & 0xffffffff)) & 0xffffffff;
    return Iface(
      name: name,
      ip: address,
      netmask: intToIp(mask),
      prefix: prefix,
      network: intToIp(net),
      broadcast: intToIp(bcast),
    );
  }
}

bool ipInSubnet(String ip, Iface iface) {
  final n = ipToInt(ip);
  if (n == null) return false;
  return (n & maskInt(iface.prefix)) == ipToInt(iface.network);
}

bool ipInAnySubnet(String ip, Iterable<Iface> ifaces) =>
    ifaces.any((i) => ipInSubnet(ip, i));

/// Sweep targets for one interface. Never leaves the interface's own subnet.
///  - subnets up to [maxHosts] addresses (default /24 = 254): every host.
///  - larger subnets (e.g. a /16 or link-local 169.254.0.0/16): only the /24
///    around the phone's own address, plus [extraIps] inside the subnet.
List<String> enumerateTargets(Iface iface,
    {int maxHosts = 254, List<String> extraIps = const []}) {
  final net = ipToInt(iface.network)!;
  final self = ipToInt(iface.ip)!;
  final bcast = ipToInt(iface.broadcast)!;
  final seen = <int>{};
  final out = <String>[];
  void add(int n) {
    if (n == self || !seen.add(n)) return;
    out.add(intToIp(n));
  }

  if (iface.hostCount <= maxHosts) {
    for (var n = net + 1; n < bcast; n++) {
      add(n);
    }
  } else {
    final base = self & 0xffffff00;
    for (var n = base + 1; n < base + 255; n++) {
      if (ipInSubnet(intToIp(n), iface)) add(n);
    }
  }
  for (final ip in extraIps) {
    final n = ipToInt(ip);
    if (n != null && ipInSubnet(ip, iface) && n != bcast && n != net) add(n);
  }
  return out;
}
