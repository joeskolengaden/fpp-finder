import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import '../core/history.dart';

// mDNS / Bonjour browse. Only sends standard read-only DNS-SD queries and
// listens for answers. FPP advertises `_fppd._udp` (and `_http._tcp`) via
// avahi, and answers `fpp.local` by default.

const mdnsServiceTypes = <String>[
  '_fppd._udp.local',
  '_http._tcp.local',
  '_wled._tcp.local',
];

/// Default FPP hostname plus names we saw before.
Future<Map<String, MdnsHit>> browseMdns({
  List<String> hostnames = const ['fpp.local'],
  Duration timeout = const Duration(milliseconds: 3000),
  void Function(String)? log,
}) async {
  final hits = <String, MdnsHit>{};
  MdnsHit entry(String ip) => hits.putIfAbsent(ip, MdnsHit.new);
  final client = MDnsClient();
  try {
    await client.start();
  } catch (e) {
    log?.call('mdns start failed: $e');
    return hits;
  }

  Future<void> resolveHost(String host, {ServiceRef? svc}) async {
    try {
      await for (final a in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(host),
          timeout: timeout)) {
        final e = entry(a.address.address);
        e.hostnames.add(host.toLowerCase().replaceAll(RegExp(r'\.$'), ''));
        if (svc != null &&
            !e.services.any((s) => s.type == svc.type && s.port == svc.port)) {
          e.services.add(svc);
        }
      }
    } catch (e) {
      log?.call('mdns A $host: $e');
    }
  }

  Future<void> browseType(String type) async {
    try {
      final tasks = <Future<void>>[];
      await for (final ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(type),
          timeout: timeout)) {
        tasks.add(() async {
          await for (final srv in client.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
              timeout: timeout)) {
            await resolveHost(srv.target, svc: ServiceRef(type, srv.port));
          }
        }());
      }
      await Future.wait(tasks);
    } catch (e) {
      log?.call('mdns PTR $type: $e');
    }
  }

  try {
    await Future.wait([
      for (final t in mdnsServiceTypes) browseType(t),
      for (final h in hostnames) resolveHost(h),
    ]).timeout(timeout * 2, onTimeout: () => const []);
  } finally {
    try {
      client.stop();
    } catch (_) {}
  }
  return hits;
}
