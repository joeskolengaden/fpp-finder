import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/fpp.dart';
import '../core/history.dart';

// Network probes. READ-ONLY by construction: the only HTTP method used anywhere
// in this app is GET (see httpGet), and TCP probes only connect and close.

const commonPorts = <(int, String)>[
  (22, 'ssh'),
  (23, 'telnet'),
  (53, 'dns'),
  (80, 'http'),
  (139, 'netbios'),
  (443, 'https'),
  (445, 'smb'),
  (554, 'rtsp'),
  (1883, 'mqtt'),
  (3389, 'rdp'),
  (5000, 'upnp/http'),
  (8000, 'http-alt'),
  (8080, 'http-alt'),
  (8081, 'http-alt'),
  (8443, 'https-alt'),
  (9100, 'printer'),
];

/// Ports used for the cheap "is anything alive at this IP?" sweep. A refused
/// connection (RST) also proves a host is alive.
const sweepPorts = <int>[80, 443, 22, 445, 8080];

class HttpResult {
  const HttpResult(this.status, this.body);
  final int status;
  final String body;
}

/// Read-only GET with hard timeout and body cap. Returns null on any failure.
Future<HttpResult?> httpGet(
  String host,
  String path, {
  int port = 80,
  Duration timeout = const Duration(milliseconds: 1500),
  int maxBytes = 512 * 1024,
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = Duration.zero
    ..userAgent = 'fpp-finder-mobile/1 (read-only probe)';
  try {
    return await () async {
      final req = await client.getUrl(Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: path)); // GET only; this is the single HTTP entry point
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      final res = await req.close();
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) return null;
      }
      return HttpResult(res.statusCode, utf8.decode(bytes, allowMalformed: true));
    }()
        .timeout(timeout + const Duration(milliseconds: 500));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Probes one host. Returns null if it is not FPP.
Future<FppInfo?> probeFpp(
  String ip, {
  int port = 80,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  Future<HttpResult?> get(String p) =>
      httpGet(ip, p, port: port, timeout: timeout);
  final v = await get('/api/fppd/version');
  if (v == null || v.status != 200) return null;
  final version = classifyVersion(v.body);
  if (!version.isFpp) return null;
  final r = await Future.wait([
    get('/api/fppd/status'),
    get('/api/fppd/multiSyncSystems'),
    get('/api/system/info'),
    get('/api/plugin'),
    get('/api/network/interface'),
  ]);
  bool ok(HttpResult? x) => x != null && x.status == 200;
  return buildFppInfo(
    ip: ip,
    version: version,
    status: ok(r[0]) ? classifyStatus(r[0]!.body) : null,
    multisync: ok(r[1]) ? classifyMultiSync(r[1]!.body, ip) : null,
    sysinfo: ok(r[2]) ? classifySystemInfo(r[2]!.body) : null,
    plugins: ok(r[3]) ? classifyPlugins(r[3]!.body) : const [],
    interfaces: ok(r[4]) ? classifyInterfaces(r[4]!.body) : const [],
  );
}

enum TcpResult { open, closed, filtered }

/// Maps a failed connect to "closed" (RST received => host is alive) or
/// "filtered" (silence / unreachable). Codes: ECONNREFUSED is 111 on
/// Linux/Android, 61 on macOS/iOS, 10061 on Windows.
TcpResult classifyConnectError(int? errorCode, String message) {
  if (errorCode == 111 || errorCode == 61 || errorCode == 10061) {
    return TcpResult.closed;
  }
  if (RegExp(r'refused', caseSensitive: false).hasMatch(message)) {
    return TcpResult.closed;
  }
  return TcpResult.filtered;
}

Future<TcpResult> tcpProbe(String ip, int port,
    {Duration timeout = const Duration(milliseconds: 600)}) async {
  try {
    final s = await Socket.connect(ip, port, timeout: timeout);
    s.destroy();
    return TcpResult.open;
  } on SocketException catch (e) {
    return classifyConnectError(e.osError?.errorCode, e.message);
  } catch (_) {
    return TcpResult.filtered;
  }
}

/// Runs [fn] over [items] with at most [limit] in flight; keeps order.
Future<List<R?>> mapLimit<T, R>(
    List<T> items, int limit, Future<R> Function(T item, int index) fn) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  final n = items.isEmpty ? 0 : limit.clamp(1, items.length);
  await Future.wait(List.generate(n, (_) async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      try {
        results[i] = await fn(items[i], i);
      } catch (_) {
        results[i] = null;
      }
    }
  }));
  return results;
}

Future<({List<OpenPort> open, bool alive})> scanPorts(
  String ip, {
  Duration timeout = const Duration(milliseconds: 500),
  int concurrency = 8,
}) async {
  final res = await mapLimit(commonPorts, concurrency,
      (p, _) => tcpProbe(ip, p.$1, timeout: timeout));
  final open = <OpenPort>[];
  var alive = false;
  for (var i = 0; i < commonPorts.length; i++) {
    if (res[i] == TcpResult.open) {
      open.add(OpenPort(commonPorts[i].$1, commonPorts[i].$2));
      alive = true;
    } else if (res[i] == TcpResult.closed) {
      alive = true;
    }
  }
  return (open: open, alive: alive);
}
