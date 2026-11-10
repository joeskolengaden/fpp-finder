import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpp_finder/net/probe.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  test('mapLimit respects the concurrency limit and preserves order', () async {
    var cur = 0, max = 0;
    final out = await mapLimit<int, int>([1, 2, 3, 4, 5, 6, 7, 8], 3, (x, _) async {
      cur++;
      if (cur > max) max = cur;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cur--;
      return x * 2;
    });
    expect(out, [2, 4, 6, 8, 10, 12, 14, 16]);
    expect(max, lessThanOrEqualTo(3));
  });

  test('classifyConnectError: RST means closed (host alive), silence means filtered', () {
    expect(classifyConnectError(111, 'Connection refused'), TcpResult.closed);
    expect(classifyConnectError(61, 'Connection refused'), TcpResult.closed);
    expect(classifyConnectError(10061, 'x'), TcpResult.closed);
    expect(classifyConnectError(null, 'Connection refused'), TcpResult.closed);
    expect(classifyConnectError(113, 'No route to host'), TcpResult.filtered);
    expect(classifyConnectError(65, 'No route to host'), TcpResult.filtered);
    expect(classifyConnectError(null, 'timed out'), TcpResult.filtered);
  });

  test('tcpProbe: open vs closed on loopback', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    expect(await tcpProbe('127.0.0.1', port), TcpResult.open);
    await server.close();
    expect(await tcpProbe('127.0.0.1', port), TcpResult.closed);
  });

  group('probeFpp against a fake FPP 5.4.1 (loopback HTTP server)', () {
    late HttpServer server;
    final seen = <String>[]; // "METHOD path"

    Future<void> startFake({bool fpp = true}) async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        seen.add('${req.method} ${req.uri.path}');
        String? body;
        switch (req.uri.path) {
          case '/api/fppd/version':
            body = fpp ? fx('fpp-version.json') : '<html>not fpp</html>';
          case '/api/fppd/status':
            body = fx('fpp-status.json');
          case '/api/fppd/multiSyncSystems':
            body = fx('fpp-multisync.json');
          case '/api/plugin':
            body = fx('fpp-plugins.json');
          case '/api/network/interface':
            body = fx('fpp-interfaces.json');
        }
        if (body == null) {
          req.response.statusCode = 404; // like FPP 5.4's /api/system/info
          req.response.write(fx('fpp-sysinfo-404.html'));
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(body);
        }
        req.response.close();
      });
    }

    tearDown(() async => server.close(force: true));

    test('classifies a real FPP and issues only GET requests', () async {
      await startFake();
      final info = await probeFpp('127.0.0.1', port: server.port);
      expect(info, isNotNull);
      expect(info!.version, '5.4.1');
      expect(info.mode, 'player');
      expect(info.platform, 'BeagleBone');
      expect(info.hostname, 'FPP');
      expect(info.plugins, contains('pixelselect'));
      expect(info.interfaces.single.mac, '04:23:22:aa:bb:cc');
      expect(seen, isNotEmpty);
      expect(seen.every((s) => s.startsWith('GET ')), isTrue, reason: seen.join(', '));
      expect(seen.toSet(), {
        'GET /api/fppd/version',
        'GET /api/fppd/status',
        'GET /api/fppd/multiSyncSystems',
        'GET /api/system/info',
        'GET /api/plugin',
        'GET /api/network/interface',
      });
    });

    test('a non-FPP web server is rejected after a single GET', () async {
      await startFake(fpp: false);
      expect(await probeFpp('127.0.0.1', port: server.port), isNull);
      expect(seen, ['GET /api/fppd/version']);
    });

    test('nothing listening -> null, quickly', () async {
      await startFake();
      final port = server.port;
      await server.close(force: true);
      final sw = Stopwatch()..start();
      expect(await probeFpp('127.0.0.1', port: port, timeout: const Duration(milliseconds: 500)), isNull);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0); // for tearDown
    });
  });
}
