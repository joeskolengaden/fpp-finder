import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpp_finder/core/fpp.dart';
import 'package:fpp_finder/core/history.dart';
import 'package:fpp_finder/core/oui.dart';
import 'package:fpp_finder/core/subnet.dart';
import 'package:fpp_finder/ui/format.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

Iface mk(String ip, String mask, [String name = 'wifi']) =>
    Iface.from(name, ip, mask)!;

void main() {
  // ------------------------------------------------------------ subnet
  group('subnet', () {
    test('Iface.from computes network / broadcast / cidr', () {
      final i = mk('10.213.125.112', '255.255.255.0');
      expect(i.cidr, '10.213.125.0/24');
      expect(i.broadcast, '10.213.125.255');
      expect(i.hostCount, 254);
      expect(i.linkLocal, isFalse);
      final ll = mk('169.254.1.110', '255.255.0.0');
      expect(ll.cidr, '169.254.0.0/16');
      expect(ll.linkLocal, isTrue);
    });

    test('rejects loopback, /32, bad address; unknown mask falls back to /24', () {
      expect(Iface.from('lo', '127.0.0.1', '255.0.0.0'), isNull);
      expect(Iface.from('tun', '10.0.0.1', '255.255.255.255'), isNull);
      expect(Iface.from('x', 'nope', '255.255.255.0'), isNull);
      expect(Iface.from('x', '0.0.0.0', '255.255.255.0'), isNull);
      expect(Iface.from('x', '192.168.1.5', null)!.cidr, '192.168.1.0/24');
      expect(Iface.from('x', '192.168.1.5', '255.0.255.0')!.cidr, '192.168.1.0/24');
    });

    test('/24 sweep = 253 hosts, excludes self / network / broadcast', () {
      final t = enumerateTargets(mk('192.168.1.10', '255.255.255.0'));
      expect(t.length, 253);
      expect(t, isNot(contains('192.168.1.10')));
      expect(t, isNot(contains('192.168.1.0')));
      expect(t, isNot(contains('192.168.1.255')));
      expect(t.first, '192.168.1.1');
    });

    test('/16 and /22 are capped to the phone\'s own /24', () {
      final big = mk('192.168.5.77', '255.255.0.0');
      final t = enumerateTargets(big);
      expect(t.length, 253);
      expect(t.every((ip) => ip.startsWith('192.168.5.')), isTrue);
      final mid = mk('10.0.2.9', '255.255.252.0'); // /22 = 1022 hosts > 254
      final t2 = enumerateTargets(mid);
      expect(t2.length, 253);
      expect(t2.every((ip) => ip.startsWith('10.0.2.')), isTrue);
    });

    test('a /25 only sweeps its 126 hosts', () {
      final t = enumerateTargets(mk('192.168.1.130', '255.255.255.128'));
      expect(t.length, 125); // 126 minus self
      expect(t.first, '192.168.1.129');
      expect(t.last, '192.168.1.254');
    });

    test('extraIps are added only when inside the subnet', () {
      final ll = mk('169.254.1.110', '255.255.0.0');
      final t = enumerateTargets(ll,
          extraIps: ['169.254.9.67', '10.0.0.5', '169.254.255.255', '169.254.0.0']);
      expect(t, contains('169.254.9.67'));
      expect(t, contains('169.254.1.77'));
      expect(t, isNot(contains('169.254.1.110')));
      expect(t, isNot(contains('10.0.0.5')));
      expect(t, isNot(contains('169.254.255.255')));
      expect(t, isNot(contains('169.254.0.0')));
    });

    test('ipInSubnet / ipInAnySubnet', () {
      final ifs = [mk('10.213.125.112', '255.255.255.0'), mk('169.254.1.110', '255.255.0.0')];
      expect(ipInAnySubnet('169.254.9.67', ifs), isTrue);
      expect(ipInAnySubnet('10.213.125.230', ifs), isTrue);
      expect(ipInAnySubnet('10.213.126.230', ifs), isFalse);
      expect(ipInAnySubnet('8.8.8.8', ifs), isFalse);
    });

    test('netmask and int helpers', () {
      expect(prefixFromNetmask('255.255.254.0'), 23);
      expect(prefixFromNetmask('255.0.255.0'), isNull);
      expect(intToIp(ipToInt('1.2.3.4')!), '1.2.3.4');
      expect(ipToInt('300.1.1.1'), isNull);
      expect(ipToInt('1.2.3'), isNull);
      expect(ipToInt('255.255.255.255'), 0xffffffff);
    });
  });

  // ------------------------------------------------------------ OUI
  group('oui', () {
    test('normalizeMac handles formats', () {
      expect(normalizeMac('4:23:22:aa:bb:cc'), '04:23:22:aa:bb:cc');
      expect(normalizeMac('A4-2B-B0-12-34-56'), 'a4:2b:b0:12:34:56');
      expect(normalizeMac('a42b.b012.3456'), 'a4:2b:b0:12:34:56');
      expect(normalizeMac('nope'), isNull);
      expect(normalizeMac('(incomplete)'), isNull);
      expect(normalizeMac(null), isNull);
    });

    final table = OuiTable.fromJsonString(File('assets/oui-data.json').readAsStringSync());

    test('bundled IEEE table: vendors that matter for FPP setups', () {
      expect(table.lookupVendor('04:23:22:aa:bb:cc'), 'Texas Instruments');
      expect(table.lookupVendor('b8:27:eb:00:00:01'), 'Raspberry Pi');
      expect(table.lookupVendor('dc:a6:32:00:00:01'), 'Raspberry Pi');
      expect(table.lookupVendor('d8:3a:dd:00:00:01'), 'Raspberry Pi');
      expect(table.lookupVendor('24:0a:c4:00:00:01'), 'Espressif');
      expect(table.lookupVendor('fc-ec-da-11-22-33'), 'Ubiquiti');
      expect(table.lookupVendor('12:5a:ae:ea:09:63'), 'Private (randomised MAC)');
      expect(table.lookupVendor('garbage'), isNull);
    });

    test('multicast / broadcast detection', () {
      expect(isMulticastOrBroadcastMac('ff:ff:ff:ff:ff:ff'), isTrue);
      expect(isMulticastOrBroadcastMac('01:00:5e:7f:ff:fa'), isTrue);
      expect(isMulticastOrBroadcastMac('04:23:22:aa:bb:cc'), isFalse);
    });
  });

  // ------------------------------------------------------------ FPP classification
  group('fpp classification (fixtures from a real FPP 5.4.1 BeagleBone)', () {
    test('classifyVersion positive', () {
      final v = classifyVersion(fx('fpp-version.json'));
      expect(v.isFpp, isTrue);
      expect(v.version, '5.4.1');
      expect(v.branch, 'v5.4');
      expect(v.major, 5);
      expect(v.minor, 4);
    });

    test('classifyVersion rejects non-FPP bodies', () {
      for (final body in <Object?>[
        '<html>Hello</html>',
        '',
        null,
        '{"version":"1.2"}',
        '[]',
        '{"hello":"world"}',
        fx('fpp-sysinfo-404.html'),
      ]) {
        expect(classifyVersion(body).isFpp, isFalse, reason: '$body'.substring(0, ('$body').length.clamp(0, 30)));
      }
    });

    test('tolerates PHP notices before the JSON', () {
      final v = classifyVersion('<br />\n<b>Notice</b>: x in y on line 1<br />\n${fx('fpp-version.json')}');
      expect(v.isFpp, isTrue);
      expect(v.version, '5.4.1');
    });

    test('status -> mode', () {
      final s = classifyStatus(fx('fpp-status.json'))!;
      expect(s.mode, 'player');
      expect(s.fppd, 'running');
      expect(s.status, 'testing');
      expect(s.bridging, isFalse);
      expect(classifyStatus('{"mode":8}')!.mode, 'remote');
      expect(classifyStatus('{"mode":2,"mode_name":"master"}')!.mode, 'player');
      expect(classifyStatus('{"mode":2,"mode_name":"player","bridging":true}')!.bridging, isTrue);
      expect(classifyStatus('nope'), isNull);
    });

    test('multisync -> platform BeagleBone', () {
      final m = classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67')!;
      expect(m.platform, 'BeagleBone');
      expect(m.type, 'BeagleBone Green');
      expect(m.hostname, 'FPP');
      expect(m.version, '5.4.1');
      expect(m.mode, 'player');
      expect(m.peers, isEmpty);
    });

    test('multisync peers are the non-local systems', () {
      const body =
          '{"systems":[{"address":"10.0.0.5","hostname":"a","local":1,"type":"Raspberry Pi"},'
          '{"address":"10.0.0.6","hostname":"b","version":"6.0","type":"Pi 4"}]}';
      final m = classifyMultiSync(body, '10.0.0.5')!;
      expect(m.platform, 'Raspberry Pi');
      expect(m.peers.map((p) => p.address), ['10.0.0.6']);
      expect(classifyMultiSync('{"systems":[]}', '1.1.1.1'), isNull);
    });

    test('platformFamily', () {
      expect(platformFamily('Raspberry Pi 4 Model B'), 'Raspberry Pi');
      expect(platformFamily('TI AM335x BeagleBone Black'), 'BeagleBone');
      expect(platformFamily('Pi Zero 2'), 'Raspberry Pi');
      expect(platformFamily(''), isNull);
    });

    test('system info (newer FPP) and the 5.4 404 page', () {
      final i = classifySystemInfo(
          '{"HostName":"light-show","Platform":"Raspberry Pi","Variant":"Pi 4","Mode":"player","Version":"7.0"}')!;
      expect(i.hostname, 'light-show');
      expect(i.platform, 'Raspberry Pi');
      expect(i.mode, 'player');
      expect(classifySystemInfo(fx('fpp-sysinfo-404.html')), isNull);
    });

    test('plugins list (strings and object forms)', () {
      expect(classifyPlugins(fx('fpp-plugins.json')),
          ['FPP-OLED-Custom-Logo', 'pixelselect', 'credits', 'fpp-winterlights-test-mode']);
      expect(classifyPlugins('[{"name":"a"},{"repoName":"b"},"c"]'), ['a', 'b', 'c']);
      expect(classifyPlugins('{"x":1}'), isEmpty);
    });

    test('interfaces', () {
      final i = classifyInterfaces(fx('fpp-interfaces.json'));
      expect(i.length, 1);
      expect(i[0].name, 'eth0');
      expect(i[0].mac, '04:23:22:aa:bb:cc');
      expect(i[0].addrs, ['169.254.9.67']);
    });

    test('buildFppInfo merges the real device responses', () {
      final info = buildFppInfo(
        ip: '169.254.9.67',
        version: classifyVersion(fx('fpp-version.json')),
        status: classifyStatus(fx('fpp-status.json')),
        multisync: classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67'),
        plugins: classifyPlugins(fx('fpp-plugins.json')),
        interfaces: classifyInterfaces(fx('fpp-interfaces.json')),
      )!;
      expect(info.version, '5.4.1');
      expect(info.mode, 'player');
      expect(info.modeLabel, 'player');
      expect(info.platform, 'BeagleBone');
      expect(info.hostname, 'FPP');
      expect(info.plugins.length, 4);
      expect(info.url, 'http://169.254.9.67/');
      expect(buildFppInfo(ip: '1.1.1.1', version: const VersionInfo(isFpp: false)), isNull);
    });

    test('player + bridge label', () {
      final info = buildFppInfo(
        ip: '10.0.0.2',
        version: classifyVersion(fx('fpp-version.json')),
        status: classifyStatus('{"mode":2,"mode_name":"player","bridging":true}'),
      )!;
      expect(info.modeLabel, 'player + bridge');
    });

    test('FppInfo survives a JSON round trip (history persistence)', () {
      final info = buildFppInfo(
        ip: '169.254.9.67',
        version: classifyVersion(fx('fpp-version.json')),
        status: classifyStatus(fx('fpp-status.json')),
        multisync: classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67'),
        plugins: classifyPlugins(fx('fpp-plugins.json')),
        interfaces: classifyInterfaces(fx('fpp-interfaces.json')),
      )!;
      final back = FppInfo.fromJson(info.toJson());
      expect(back.toJson(), info.toJson());
    });
  });

  // ------------------------------------------------------------ history / merge
  group('history', () {
    final table = OuiTable.fromJsonString(File('assets/oui-data.json').readAsStringSync());
    final wifi = [mk('192.168.1.10', '255.255.255.0')];

    ScanHost fppHost(String ip) {
      final h = ScanHost(ip)
        ..alive = true
        ..via.add('tcp')
        ..ports = [const OpenPort(80, 'http')]
        ..fpp = buildFppInfo(
          ip: ip,
          version: classifyVersion(fx('fpp-version.json')),
          status: classifyStatus(fx('fpp-status.json')),
          multisync: classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67'),
          interfaces: [
            NetIface(name: 'eth0', mac: '04:23:22:aa:bb:cc', addrs: [ip])
          ],
        );
      return h;
    }

    ScanHost plain(String ip) => ScanHost(ip)
      ..alive = true
      ..via.add('tcp');

    ScanResult run(HistoryState s, List<ScanHost> hosts, int now) =>
        mergeScan(s, hosts, started: now - 1000, now: now, interfaces: wifi, oui: table);

    test('first scan flags nothing NEW; later scan flags only the newcomer', () {
      final s = HistoryState();
      final r1 = run(s, [fppHost('192.168.1.50'), plain('192.168.1.2')], 100000);
      expect(r1.firstRun, isTrue);
      expect(r1.devices.any((d) => d.isNew), isFalse);

      final r2 = run(s, [fppHost('192.168.1.50'), plain('192.168.1.2'), plain('192.168.1.99')], 200000);
      expect(r2.firstRun, isFalse);
      expect(r2.devices.where((d) => d.isNew).map((d) => d.ip), ['192.168.1.99']);
    });

    test('FPP device: MAC comes from its own API, vendor looked up, history kept', () {
      final s = HistoryState();
      run(s, [fppHost('192.168.1.50')], 100000);
      final r = run(s, [fppHost('192.168.1.50')], 200000);
      final d = r.devices.single;
      expect(d.isFpp, isTrue);
      expect(d.mac, '04:23:22:aa:bb:cc');
      expect(d.macSource, 'fpp');
      expect(d.vendor, 'Texas Instruments');
      expect(d.hostname, 'FPP');
      expect(d.firstSeen, 100000);
      expect(d.lastSeen, 200000);
      expect(d.isNew, isFalse);
    });

    test('a device that gains a MAC inherits its ip: history', () {
      final s = HistoryState();
      run(s, [plain('192.168.1.50')], 100000);
      expect(s.devices.keys, ['ip:192.168.1.50']);
      final r = run(s, [fppHost('192.168.1.50')], 200000);
      expect(s.devices.keys, ['04:23:22:aa:bb:cc']);
      expect(r.devices.single.firstSeen, 100000);
    });

    test('missing devices stay as offline, then expire after 7 days', () {
      final s = HistoryState();
      run(s, [plain('192.168.1.2'), plain('192.168.1.3')], 1000);
      final r = run(s, [plain('192.168.1.2')], 5000);
      expect(r.devices.first.ip, '192.168.1.2'); // online sorts first
      final off = r.devices.firstWhere((d) => d.ip == '192.168.1.3');
      expect(off.online, isFalse);
      expect(off.confidence, 'offline');
      final later = run(s, [plain('192.168.1.2')], 1000 + offlineRetainMs + 5000);
      expect(later.devices.any((d) => d.ip == '192.168.1.3'), isFalse);
      expect(s.devices.containsKey('ip:192.168.1.3'), isTrue); // still in history (30 d)
      run(s, [plain('192.168.1.2')], 1000 + retainMs + 5000);
      expect(s.devices.containsKey('ip:192.168.1.3'), isFalse);
    });

    test('a silent host without a MAC is a fresh ip-keyed row (no stale FPP verdict)', () {
      final s = HistoryState();
      run(s, [fppHost('192.168.1.50')], 1000);
      final silent = ScanHost('192.168.1.50')
        ..alive = true
        ..via.add('tcp');
      final r = run(s, [silent], 2000);
      // no MAC this time => keyed by ip, so it is a fresh row, not FPP
      expect(r.devices.firstWhere((d) => d.ip == '192.168.1.50' && d.online).isFpp, isFalse);
    });

    test('history JSON round trip and corrupt input tolerance', () {
      final s = HistoryState();
      run(s, [fppHost('192.168.1.50'), plain('192.168.1.2')], 100000);
      final back = HistoryState.fromJson(s.toJson());
      expect(back.devices.keys.toSet(), s.devices.keys.toSet());
      expect(back.lastScan!.ended, 100000);
      expect(back.devices['04:23:22:aa:bb:cc']!.fpp!.plugins, isEmpty);
      expect(HistoryState.fromJson('garbage').devices, isEmpty);
      expect(HistoryState.fromJson({'version': 2}).devices, isEmpty);
    });

    test('bestName priority: fpp > mdns(.local) > resolved > reverse dns', () {
      final h = ScanHost('1.1.1.1')..alive = true;
      expect(bestName(h), isNull);
      h.dnsName = 'router.lan';
      expect(bestName(h)!.source, 'dns');
      h.resolvedName = 'fpp.local';
      expect(bestName(h)!.source, 'dns-local');
      h.mdns = (MdnsHit()..hostnames.addAll(['a', 'b.local']));
      expect(bestName(h)!.name, 'b.local');
      h.fpp = fppHost('1.1.1.1').fpp;
      expect(bestName(h)!.source, 'fpp');
    });

    test('sort: online first, most recent first, FPP pin optional', () {
      Device d(String ip, bool online, int last, bool fpp) => Device(
            key: ip,
            ip: ip,
            firstSeen: 1,
            lastSeen: last,
            online: online,
            fpp: fpp ? fppHost(ip).fpp : null,
          );
      final list = [
        d('10.0.0.2', true, 100, false),
        d('10.0.0.3', true, 300, false),
        d('10.0.0.4', false, 900, true),
        d('10.0.0.5', true, 200, true),
      ];
      expect(sortDevices([...list]).map((x) => x.ip),
          ['10.0.0.3', '10.0.0.5', '10.0.0.2', '10.0.0.4']);
      expect(sortDevices([...list], pinFpp: true).map((x) => x.ip),
          ['10.0.0.5', '10.0.0.4', '10.0.0.3', '10.0.0.2']);
    });
  });

  group('format', () {
    test('fmtAgo', () {
      const now = 1000000000;
      expect(fmtAgo(now - 5000, now: now), 'just now');
      expect(fmtAgo(now - 45000, now: now), '45s ago');
      expect(fmtAgo(now - 5 * 60000, now: now), '5 min ago');
      expect(fmtAgo(now - 3 * 3600000, now: now), '3 h ago');
      expect(fmtAgo(now - 2 * 86400000, now: now), '2 d ago');
    });
  });
}
