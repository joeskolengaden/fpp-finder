'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fx = (n) => fs.readFileSync(path.join(__dirname, 'fixtures', n), 'utf8');

const { parseArp, isUsableArpEntry } = require('../src/core/arp');
const oui = require('../src/core/oui');
const subnet = require('../src/core/subnet');
const fpp = require('../src/core/fpp');
const { parsePingPacket } = require('../src/core/multisync');
const { sortDevices } = require('../src/core/scanner');
const { mapLimit } = require('../src/core/ports');

// ---------------------------------------------------------------- ARP
test('arp: macOS output, leading-zero-less MACs normalised, incomplete skipped', () => {
  const e = parseArp(fx('arp-macos.txt'));
  const byIp = Object.fromEntries(e.map((x) => [x.ip, x]));
  assert.equal(byIp['169.254.9.67'].mac, '04:23:22:aa:bb:cc');
  assert.equal(byIp['169.254.9.67'].hostname, 'fpp.local');
  assert.equal(byIp['169.254.9.67'].iface, 'en5');
  assert.equal(byIp['10.213.125.112'].mac, '12:5a:ae:ea:09:63');
  assert.equal(byIp['10.213.125.112'].permanent, true);
  assert.equal(byIp['10.213.125.230'].hostname, null);
  assert.ok(!byIp['10.213.125.1'], 'incomplete entry must be dropped');
});

test('arp: usable filter drops broadcast + multicast', () => {
  const usable = parseArp(fx('arp-macos.txt')).filter(isUsableArpEntry).map((x) => x.ip).sort();
  assert.deepEqual(usable, ['10.213.125.112', '10.213.125.230', '169.254.9.67']);
});

test('arp: Windows output with CRLF, per-interface headers, dash MACs', () => {
  const e = parseArp(fx('arp-windows.txt'));
  const byIp = Object.fromEntries(e.map((x) => [x.ip, x]));
  assert.equal(byIp['192.168.1.1'].mac, 'a4:2b:b0:12:34:56');
  assert.equal(byIp['192.168.1.1'].iface, '192.168.1.10');
  assert.equal(byIp['192.168.1.1'].type, 'dynamic');
  assert.equal(byIp['169.254.9.67'].iface, '169.254.1.110');
  assert.equal(byIp['192.168.1.255'].type, 'static');
  const usable = e.filter(isUsableArpEntry).map((x) => x.ip).sort();
  assert.deepEqual(usable, ['169.254.9.67', '192.168.1.1', '192.168.1.42']);
});

test('arp: localised Windows (German) headers still parse', () => {
  const e = parseArp(fx('arp-windows-de.txt'));
  assert.equal(e.length, 2);
  assert.equal(e[1].mac, '24:0a:c4:11:22:33');
  assert.equal(e[1].iface, '192.168.0.5');
});

test('arp: Linux net-tools format', () => {
  const e = parseArp(fx('arp-linux.txt'));
  assert.equal(e.length, 2);
  assert.equal(e[0].hostname, '_gateway');
  assert.equal(e[0].iface, 'eth0');
  assert.equal(e[1].mac, 'dc:a6:32:01:02:03');
});

test('arp: garbage / empty input', () => {
  assert.deepEqual(parseArp(''), []);
  assert.deepEqual(parseArp(null), []);
  assert.deepEqual(parseArp('nothing useful here\n'), []);
});

// ---------------------------------------------------------------- OUI
test('oui: normalizeMac handles formats', () => {
  assert.equal(oui.normalizeMac('4:23:22:aa:bb:cc'), '04:23:22:aa:bb:cc');
  assert.equal(oui.normalizeMac('A4-2B-B0-12-34-56'), 'a4:2b:b0:12:34:56');
  assert.equal(oui.normalizeMac('a42b.b012.3456'), 'a4:2b:b0:12:34:56');
  assert.equal(oui.normalizeMac('nope'), null);
  assert.equal(oui.normalizeMac('(incomplete)'), null);
});

test('oui: vendor lookup for the vendors FPP setups care about', () => {
  assert.equal(oui.lookupVendor('04:23:22:aa:bb:cc'), 'Texas Instruments');
  assert.equal(oui.lookupVendor('b8:27:eb:00:00:01'), 'Raspberry Pi');
  assert.equal(oui.lookupVendor('dc:a6:32:00:00:01'), 'Raspberry Pi');
  assert.equal(oui.lookupVendor('d8:3a:dd:00:00:01'), 'Raspberry Pi');
  assert.equal(oui.lookupVendor('24:0a:c4:00:00:01'), 'Espressif');
  assert.equal(oui.lookupVendor('fc-ec-da-11-22-33'), 'Ubiquiti');
  assert.equal(oui.lookupVendor('14:cc:20:00:00:01'), 'TP-Link');
  assert.equal(oui.lookupVendor('00:14:6c:00:00:01'), 'Netgear');
  assert.equal(oui.lookupVendor('12:5a:ae:ea:09:63'), 'Private (randomised MAC)');
  assert.equal(oui.lookupVendor('garbage'), null);
});

test('oui: multicast/broadcast detection', () => {
  assert.ok(oui.isMulticastOrBroadcastMac('ff:ff:ff:ff:ff:ff'));
  assert.ok(oui.isMulticastOrBroadcastMac('01:00:5e:7f:ff:fa'));
  assert.ok(!oui.isMulticastOrBroadcastMac('04:23:22:aa:bb:cc'));
});

// ---------------------------------------------------------------- subnet
const mkIf = (name, address, netmask) => ({ [name]: [{ address, netmask, family: 'IPv4', internal: false, mac: '00:00:00:00:00:00' }] });

test('subnet: activeInterfaces filters loopback/ipv6/internal and computes network', () => {
  const nets = {
    lo0: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', internal: true }],
    en0: [{ address: '10.213.125.112', netmask: '255.255.255.0', family: 'IPv4', internal: false }, { address: 'fe80::1', netmask: 'ffff:ffff:ffff:ffff::', family: 'IPv6', internal: false }],
    en5: [{ address: '169.254.1.110', netmask: '255.255.0.0', family: 'IPv4', internal: false }],
    tun: [{ address: '10.0.0.1', netmask: '255.255.255.255', family: 'IPv4', internal: false }],
  };
  const a = subnet.activeInterfaces(nets);
  assert.deepEqual(a.map((x) => x.name), ['en0', 'en5']);
  assert.equal(a[0].cidr, '10.213.125.0/24');
  assert.equal(a[0].broadcast, '10.213.125.255');
  assert.equal(a[0].hostCount, 254);
  assert.equal(a[1].cidr, '169.254.0.0/16');
  assert.equal(a[1].linkLocal, true);
});

test('subnet: numeric family 4 (newer Node) accepted', () => {
  const a = subnet.activeInterfaces({ eth0: [{ address: '192.168.1.5', netmask: '255.255.255.0', family: 4, internal: false }] });
  assert.equal(a.length, 1);
});

test('subnet: enumerateTargets for a /24 gives 253 hosts, excludes self/network/broadcast', () => {
  const ifc = subnet.activeInterfaces(mkIf('en0', '192.168.1.10', '255.255.255.0'))[0];
  const t = subnet.enumerateTargets(ifc);
  assert.equal(t.length, 253);
  assert.ok(!t.includes('192.168.1.10') && !t.includes('192.168.1.0') && !t.includes('192.168.1.255'));
  assert.equal(t[0], '192.168.1.1');
});

test('subnet: /16 link-local sweeps own /24 + known extras only (never whole /16)', () => {
  const ifc = subnet.activeInterfaces(mkIf('en5', '169.254.1.110', '255.255.0.0'))[0];
  const t = subnet.enumerateTargets(ifc, { extraIps: ['169.254.9.67', '10.0.0.5', '169.254.255.255'] });
  assert.ok(t.length < 300, `got ${t.length}`);
  assert.ok(t.includes('169.254.9.67'), 'ARP-known link-local host must be included');
  assert.ok(t.includes('169.254.1.77'));
  assert.ok(!t.includes('169.254.1.110'));
  assert.ok(!t.includes('10.0.0.5'), 'outside the interface subnet');
  assert.ok(!t.includes('169.254.255.255'), 'broadcast');
});

test('subnet: ipInSubnet / ipInAnySubnet', () => {
  const nets = { ...mkIf('a', '10.213.125.112', '255.255.255.0'), ...mkIf('b', '169.254.1.110', '255.255.0.0') };
  const ifs = subnet.activeInterfaces(nets);
  assert.ok(subnet.ipInAnySubnet('169.254.9.67', ifs));
  assert.ok(subnet.ipInAnySubnet('10.213.125.230', ifs));
  assert.ok(!subnet.ipInAnySubnet('10.213.126.230', ifs));
  assert.ok(!subnet.ipInAnySubnet('8.8.8.8', ifs));
});

test('subnet: netmask and int helpers', () => {
  assert.equal(subnet.prefixFromNetmask('255.255.254.0'), 23);
  assert.equal(subnet.prefixFromNetmask('255.0.255.0'), null);
  assert.equal(subnet.intToIp(subnet.ipToInt('1.2.3.4')), '1.2.3.4');
  assert.equal(subnet.ipToInt('300.1.1.1'), null);
});

// ---------------------------------------------------------------- FPP classification
test('fpp: classifyVersion positive on real FPP 5.4.1 response', () => {
  const v = fpp.classifyVersion(fx('fpp-version.json'));
  assert.equal(v.isFpp, true);
  assert.equal(v.version, '5.4.1');
  assert.equal(v.branch, 'v5.4');
  assert.equal(v.major, 5);
  assert.equal(v.minor, 4);
});

test('fpp: classifyVersion rejects non-FPP bodies', () => {
  for (const body of ['<html>Hello</html>', '', null, '{"version":"1.2"}', '[]', '{"hello":"world"}', fx('fpp-sysinfo-404.html')]) {
    assert.equal(fpp.classifyVersion(body).isFpp, false, String(body).slice(0, 30));
  }
});

test('fpp: classifyVersion tolerates PHP notices before the JSON', () => {
  const v = fpp.classifyVersion('<br />\n<b>Notice</b>: x in y on line 1<br />\n' + fx('fpp-version.json'));
  assert.equal(v.isFpp, true);
});

test('fpp: status -> mode', () => {
  const s = fpp.classifyStatus(fx('fpp-status.json'));
  assert.equal(s.mode, 'player');
  assert.equal(s.fppd, 'running');
  assert.equal(fpp.classifyStatus('{"mode":8}').mode, 'remote');
  assert.equal(fpp.classifyStatus('{"mode":2,"mode_name":"master"}').mode, 'player');
  assert.equal(fpp.classifyStatus('{"mode":2,"mode_name":"player","bridging":true}').bridging, true);
  assert.equal(fpp.classifyStatus('nope'), null);
});

test('fpp: multisync -> platform BeagleBone', () => {
  const m = fpp.classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67');
  assert.equal(m.platform, 'BeagleBone');
  assert.equal(m.type, 'BeagleBone Green');
  assert.equal(m.hostname, 'FPP');
  assert.equal(m.version, '5.4.1');
});

test('fpp: platformFamily', () => {
  assert.equal(fpp.platformFamily('Raspberry Pi 4 Model B'), 'Raspberry Pi');
  assert.equal(fpp.platformFamily('TI AM335x BeagleBone Black'), 'BeagleBone');
  assert.equal(fpp.platformFamily('Pi Zero 2'), 'Raspberry Pi');
});

test('fpp: plugins list (strings and object forms)', () => {
  assert.deepEqual(fpp.classifyPlugins(fx('fpp-plugins.json')), ['FPP-OLED-Custom-Logo', 'pixelselect', 'credits', 'fpp-winterlights-test-mode']);
  assert.deepEqual(fpp.classifyPlugins('[{"name":"a"},{"repoName":"b"},"c"]'), ['a', 'b', 'c']);
  assert.deepEqual(fpp.classifyPlugins('{"x":1}'), []);
});

test('fpp: interfaces', () => {
  const i = fpp.classifyInterfaces(fx('fpp-interfaces.json'));
  assert.equal(i[0].name, 'eth0');
  assert.equal(i[0].mac, '04:23:22:aa:bb:cc');
  assert.deepEqual(i[0].addrs, ['169.254.9.67']);
});

test('fpp: buildFppInfo merges the real device responses', () => {
  const info = fpp.buildFppInfo({
    ip: '169.254.9.67',
    version: fpp.classifyVersion(fx('fpp-version.json')),
    status: fpp.classifyStatus(fx('fpp-status.json')),
    multisync: fpp.classifyMultiSync(fx('fpp-multisync.json'), '169.254.9.67'),
    sysinfo: null,
    plugins: fpp.classifyPlugins(fx('fpp-plugins.json')),
    interfaces: fpp.classifyInterfaces(fx('fpp-interfaces.json')),
  });
  assert.equal(info.version, '5.4.1');
  assert.equal(info.mode, 'player');
  assert.equal(info.platform, 'BeagleBone');
  assert.equal(info.hostname, 'FPP');
  assert.equal(info.plugins.length, 4);
  assert.equal(info.url, 'http://169.254.9.67/');
  assert.equal(fpp.buildFppInfo({ ip: '1.1.1.1', version: { isFpp: false } }), null);
});

// ---------------------------------------------------------------- multisync ping packet
function buildPing({ ip = [169, 254, 9, 67], host = 'FPP', ver = '5.4.1', model = 'BeagleBone Green', mode = 2 } = {}) {
  const buf = Buffer.alloc(7 + 294);
  buf.write('FPPD', 0, 'ascii'); buf[4] = 4; buf.writeUInt16LE(294, 5);
  const ed = buf.subarray(7);
  ed[0] = 3; ed[1] = 0; ed[2] = 0x43; ed[3] = 0; ed[4] = 5; ed[5] = 0; ed[6] = 4; ed[7] = mode;
  ed[8] = ip[0]; ed[9] = ip[1]; ed[10] = ip[2]; ed[11] = ip[3];
  ed.write(host, 12, 'utf8'); ed.write(ver, 77, 'utf8'); ed.write(model, 118, 'utf8');
  return buf;
}
test('multisync: parses FPP ping packet', () => {
  const p = parsePingPacket(buildPing());
  assert.equal(p.address, '169.254.9.67');
  assert.equal(p.hostname, 'FPP');
  assert.equal(p.version, '5.4.1');
  assert.equal(p.model, 'BeagleBone Green');
  assert.equal(p.mode, 'player');
  assert.equal(parsePingPacket(buildPing({ mode: 8 })).mode, 'remote');
  assert.equal(parsePingPacket(buildPing({ mode: 6 })).mode, 'player');
});
test('multisync: rejects non-FPP / short / wrong-type packets', () => {
  assert.equal(parsePingPacket(Buffer.from('hello')), null);
  const sync = buildPing(); sync[4] = 1;
  assert.equal(parsePingPacket(sync), null);
  const bad = buildPing(); bad.write('XXXX', 0, 'ascii');
  assert.equal(parsePingPacket(bad), null);
});

// ---------------------------------------------------------------- sorting / pool
test('sort: online first, most recently seen first, FPP pin optional', () => {
  const d = [
    { ip: '10.0.0.2', online: true, lastSeen: 100, firstSeen: 1, isFpp: false },
    { ip: '10.0.0.3', online: true, lastSeen: 300, firstSeen: 1, isFpp: false },
    { ip: '10.0.0.4', online: false, lastSeen: 900, firstSeen: 1, isFpp: true },
    { ip: '10.0.0.5', online: true, lastSeen: 200, firstSeen: 1, isFpp: true },
  ];
  assert.deepEqual(sortDevices([...d]).map((x) => x.ip), ['10.0.0.3', '10.0.0.5', '10.0.0.2', '10.0.0.4']);
  assert.deepEqual(sortDevices([...d], { pinFpp: true }).map((x) => x.ip), ['10.0.0.5', '10.0.0.4', '10.0.0.3', '10.0.0.2']);
});

test('mapLimit respects the concurrency limit and preserves order', async () => {
  let cur = 0, max = 0;
  const out = await mapLimit([1, 2, 3, 4, 5, 6, 7, 8], 3, async (x) => {
    cur++; max = Math.max(max, cur);
    await new Promise((r) => setTimeout(r, 5));
    cur--; return x * 2;
  });
  assert.deepEqual(out, [2, 4, 6, 8, 10, 12, 14, 16]);
  assert.ok(max <= 3);
});
