import 'dart:async';
import 'dart:io';

import '../core/history.dart';
import '../core/oui.dart';
import '../core/subnet.dart';
import 'interfaces.dart';
import 'mdns.dart';
import 'probe.dart';

class ScanProgress {
  const ScanProgress(this.stage, this.done, this.total);
  final String stage; // interfaces | mdns | sweep | ports | fpp | names
  final int done;
  final int total;
}

class ScanOptions {
  const ScanOptions({
    this.sweepTimeout = const Duration(milliseconds: 600),
    this.sweepConcurrency = 128,
    this.portTimeout = const Duration(milliseconds: 500),
    this.portHostConcurrency = 12,
    this.fppTimeout = const Duration(milliseconds: 1500),
    this.fppConcurrency = 8,
    this.maxSweepHosts = 254, // cap: never more than the local /24
    this.nameTimeout = const Duration(milliseconds: 1200),
  });
  final Duration sweepTimeout;
  final int sweepConcurrency;
  final Duration portTimeout;
  final int portHostConcurrency;
  final Duration fppTimeout;
  final int fppConcurrency;
  final int maxSweepHosts;
  final Duration nameTimeout;
}

/// Orchestrates one scan: own subnet(s) -> mDNS + TCP sweep -> port scan ->
/// FPP probe -> names -> merge with history. Read-only: only TCP connects,
/// mDNS queries and HTTP GETs. Nothing is ever written to a device.
class Scanner {
  Scanner({
    required this.state,
    this.oui,
    this.options = const ScanOptions(),
    Future<List<Iface>> Function()? interfaces,
    Future<Map<String, MdnsHit>> Function(List<String> hostnames)? mdns,
    this.onProgress,
    this.log,
  })  : _interfaces = interfaces ?? detectInterfaces,
        _mdns = mdns ??
            ((names) => browseMdns(hostnames: names, log: log));

  final HistoryState state;
  final OuiTable? oui;
  final ScanOptions options;
  final void Function(ScanProgress)? onProgress;
  final void Function(String)? log;
  final Future<List<Iface>> Function() _interfaces;
  final Future<Map<String, MdnsHit>> Function(List<String>) _mdns;

  bool running = false;

  Future<ScanResult> scan() async {
    if (running) throw StateError('scan already running');
    running = true;
    final started = DateTime.now().millisecondsSinceEpoch;
    try {
      onProgress?.call(const ScanProgress('interfaces', 0, 1));
      final ifaces = await _interfaces();
      final selfIps = ifaces.map((i) => i.ip).toSet();
      final warnings = <String>[];
      if (ifaces.isEmpty) warnings.add('no-wifi');

      final hosts = <String, ScanHost>{};
      ScanHost host(String ip) => hosts.putIfAbsent(ip, () => ScanHost(ip));

      // Seeds: previously seen IPs (only needed for subnets larger than /24).
      final seedIps = <String>{};
      for (final d in state.devices.values) {
        if (ipInAnySubnet(d.ip, ifaces) && !selfIps.contains(d.ip)) {
          seedIps.add(d.ip);
        }
      }
      final names = <String>{'fpp.local'};
      for (final d in state.devices.values) {
        final h = d.fpp?.hostname ?? d.hostname;
        if (h != null && h.isNotEmpty && !h.contains('.')) names.add('$h.local');
        if (h != null && h.endsWith('.local')) names.add(h);
      }

      // ---- 1. mDNS runs in the background while we sweep.
      onProgress?.call(const ScanProgress('mdns', 0, 1));
      final mdnsFuture = ifaces.isEmpty
          ? Future.value(<String, MdnsHit>{})
          : _mdns(names.take(20).toList()).catchError((_) => <String, MdnsHit>{});

      // ---- 2. TCP sweep of our own subnet(s).
      final targets = <String>{};
      for (final ifc in ifaces) {
        targets.addAll(enumerateTargets(ifc,
            maxHosts: options.maxSweepHosts, extraIps: seedIps.toList()));
      }
      targets.removeAll(selfIps);
      final pairs = <(String, int)>[
        for (final ip in targets)
          for (final p in sweepPorts) (ip, p)
      ];
      var swept = 0;
      onProgress?.call(ScanProgress('sweep', 0, pairs.length));
      await mapLimit(pairs, options.sweepConcurrency, (pair, _) async {
        final r = await tcpProbe(pair.$1, pair.$2, timeout: options.sweepTimeout);
        if (r != TcpResult.filtered) {
          final h = host(pair.$1);
          h.alive = true;
          h.via.add('tcp');
        }
        if (++swept % 32 == 0 || swept == pairs.length) {
          onProgress?.call(ScanProgress('sweep', swept, pairs.length));
        }
      });

      // ---- 3. mDNS sightings (restricted to our own subnets).
      final mdnsHits = await mdnsFuture;
      for (final e in mdnsHits.entries) {
        if (!ipInAnySubnet(e.key, ifaces) || selfIps.contains(e.key)) continue;
        final h = host(e.key);
        h.mdns = e.value;
        h.alive = true;
        h.via.add('mdns');
        if (e.value.hostnames.contains('fpp.local')) h.resolvedName = 'fpp.local';
      }
      final live = hosts.values.where((h) => h.alive).toList();
      for (final h in live) {
        final ifc = ifaces.firstWhere((i) => ipInSubnet(h.ip, i),
            orElse: () => ifaces.first);
        h.ifaceName = ifc.name;
        h.network = ifc.cidr;
      }

      // ---- 4. port scan of live hosts.
      var pdone = 0;
      onProgress?.call(ScanProgress('ports', 0, live.length));
      await mapLimit(live, options.portHostConcurrency, (h, _) async {
        final r = await scanPorts(h.ip, timeout: options.portTimeout);
        h.ports = r.open;
        onProgress?.call(ScanProgress('ports', ++pdone, live.length));
      });

      // ---- 5. FPP probe (read-only GETs) of anything that serves port 80
      //         or advertised itself as FPP over mDNS.
      final web = live.where((h) {
        final has80 = h.ports.any((p) => p.port == 80);
        final fppSvc =
            h.mdns?.services.any((s) => s.type == '_fppd._udp.local') ?? false;
        return has80 || fppSvc;
      }).toList();
      var fdone = 0;
      onProgress?.call(ScanProgress('fpp', 0, web.length));
      await mapLimit(web, options.fppConcurrency, (h, _) async {
        try {
          h.fpp = await probeFpp(h.ip, timeout: options.fppTimeout);
        } catch (_) {
          h.fpp = null;
        }
        onProgress?.call(ScanProgress('fpp', ++fdone, web.length));
      });

      // ---- 6. reverse-DNS names for anything still unnamed.
      final unnamed = live.where((h) => bestName(h) == null).toList();
      var ndone = 0;
      onProgress?.call(ScanProgress('names', 0, unnamed.length));
      await mapLimit(unnamed, 8, (h, _) async {
        try {
          final r = await InternetAddress(h.ip)
              .reverse()
              .timeout(options.nameTimeout);
          if (r.host.isNotEmpty && r.host != h.ip) h.dnsName = r.host;
        } catch (_) {}
        onProgress?.call(ScanProgress('names', ++ndone, unnamed.length));
      });

      // ---- 7. merge with history.
      final result = mergeScan(state, live,
          started: started,
          now: DateTime.now().millisecondsSinceEpoch,
          interfaces: ifaces,
          oui: oui);
      return ScanResult(
        started: result.started,
        ended: result.ended,
        interfaces: result.interfaces,
        devices: result.devices,
        firstRun: result.firstRun,
        warnings: warnings,
      );
    } finally {
      running = false;
    }
  }
}
