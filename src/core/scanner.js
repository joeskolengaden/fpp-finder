'use strict';
// Orchestrates a scan: interface enumeration -> TCP sweep + ARP table -> port scan ->
// FPP probe -> name resolution -> merge with history. Read-only; never changes a device.
const os = require('os');
const dns = require('dns');
const { EventEmitter } = require('events');
const subnet = require('./subnet');
const { readArpTable } = require('./arp');
const { lookupVendor, normalizeMac } = require('./oui');
const { tcpProbe, scanPorts, mapLimit, COMMON_PORTS } = require('./ports');
const { probeFpp } = require('./fpp');
const { MdnsBrowser } = require('./mdns');
const { MultiSyncListener } = require('./multisync');
const store = require('./store');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const withTimeout = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(() => r(null), ms))]);

const DEFAULTS = {
  sweepPort: 80,
  sweepTimeout: 600,
  sweepConcurrency: 256,
  portTimeout: 500,
  portHostConcurrency: 24,
  fppTimeout: 1500,
  fppConcurrency: 8,
  maxSweepHosts: 1022,   // subnets larger than /22 only get the local /24 + known hosts
  nameTimeout: 1200,
  offlineRetainMs: 7 * 24 * 3600 * 1000,
};

class Scanner extends EventEmitter {
  constructor({ storeFile = null, options = {}, netifs = () => os.networkInterfaces(), log = () => {} } = {}) {
    super();
    this.opts = { ...DEFAULTS, ...options };
    this.storeFile = storeFile;
    this.netifs = netifs;
    this.log = log;
    this.state = storeFile ? store.load(storeFile) : store.emptyState();
    this.mdns = new MdnsBrowser({ log });
    this.multisync = new MultiSyncListener({ log });
    this.running = false;
    this.listening = false;
    this.last = null;
  }

  startListeners(ifaces) {
    if (this.listening) return;
    this.mdns.start(ifaces);
    this.multisync.start(ifaces);
    this.listening = true;
  }
  stop() { this.mdns.stop(); this.multisync.stop(); this.listening = false; }

  _progress(stage, done, total) { this.emit('progress', { stage, done, total }); }

  async scan() {
    if (this.running) return this.last;
    this.running = true;
    const started = Date.now();
    this.emit('start', { started });
    try {
      const ifaces = subnet.activeInterfaces(this.netifs());
      const selfIps = new Set(ifaces.map((i) => i.ip));
      // (Re)open listeners every scan so interfaces that appeared since last time are covered.
      this.stop(); this.startListeners(ifaces);
      this.mdns.query();

      this._nameHits = new Map();
      const known = new Map(); // ip -> info we accumulate
      const get = (ip) => { let k = known.get(ip); if (!k) { k = { ip, via: new Set(), alive: false }; known.set(ip, k); } return k; };

      // ---- 1. seeds: ARP table, history, mDNS, multisync (all restricted to our own subnets)
      const arp0 = (await readArpTable()).entries;
      const seedIps = new Set();
      for (const e of arp0) if (subnet.ipInAnySubnet(e.ip, ifaces) && !selfIps.has(e.ip)) seedIps.add(e.ip);
      for (const ip of this.opts.seedIps || []) if (subnet.ipInAnySubnet(ip, ifaces)) seedIps.add(ip);
      for (const d of Object.values(this.state.devices)) if (d.ip && subnet.ipInAnySubnet(d.ip, ifaces)) seedIps.add(d.ip);
      for (const ip of this.mdns.snapshot().keys()) if (subnet.ipInAnySubnet(ip, ifaces)) seedIps.add(ip);
      for (const ip of this.multisync.seen.keys()) if (subnet.ipInAnySubnet(ip, ifaces)) seedIps.add(ip);

      // Names resolved through the OS resolver (mDNSResponder on macOS, built-in mDNS on Windows 10+).
      // This finds the default FPP hostname even when ARP/multicast are hidden from this process.
      const names = new Set(['fpp.local']);
      for (const d of Object.values(this.state.devices)) {
        if (d.hostname) names.add(/\.local$/i.test(d.hostname) ? d.hostname : `${d.hostname}.local`);
        if (d.fpp && d.fpp.hostname) names.add(`${d.fpp.hostname}.local`);
      }
      await mapLimit([...names].slice(0, 40), 8, async (n) => {
        const r = await withTimeout(new Promise((res) => dns.lookup(n, { all: true, family: 4 }, (e, a) => res(e ? null : a))), 1500);
        for (const a of r || []) if (subnet.ipInAnySubnet(a.address, ifaces) && !selfIps.has(a.address)) { seedIps.add(a.address); (this._nameHits = this._nameHits || new Map()).set(a.address, n); }
      });

      // ---- 2. TCP sweep (also makes the OS ARP-resolve every live neighbour)
      const targets = new Set();
      for (const ifc of ifaces) {
        for (const ip of subnet.enumerateTargets(ifc, { maxHosts: this.opts.maxSweepHosts, extraIps: [...seedIps] })) targets.add(ip);
      }
      const list = [...targets].filter((ip) => !selfIps.has(ip));
      let swept = 0;
      this._progress('sweep', 0, list.length);
      await mapLimit(list, this.opts.sweepConcurrency, async (ip) => {
        const r = await tcpProbe(ip, this.opts.sweepPort, this.opts.sweepTimeout);
        if (r === 'open' || r === 'closed') { const k = get(ip); k.alive = true; k.via.add('tcp'); }
        if (++swept % 16 === 0 || swept === list.length) this._progress('sweep', swept, list.length);
      });
      await sleep(200); // let late ARP replies land

      // ---- 3. ARP table (MACs) + mDNS / multisync sightings
      const arpRes = await readArpTable();
      const arp = arpRes.entries;
      const warnings = [];
      if (arpRes.rawCount === 0 && process.platform !== 'win32') warnings.push('arp-empty');
      for (const e of arp) {
        if (!subnet.ipInAnySubnet(e.ip, ifaces) || selfIps.has(e.ip)) continue;
        const k = get(e.ip);
        k.mac = e.mac; k.arpName = e.hostname; k.iface = e.iface; k.via.add('arp');
      }
      for (const [ip, n] of this._nameHits || []) {
        if (subnet.ipInAnySubnet(ip, ifaces) && !selfIps.has(ip) && seedIps.has(ip)) { const k = get(ip); k.resolvedName = n; k.via.add('dns-local'); }
      }
      const mdnsSnap = this.mdns.snapshot();
      for (const [ip, m] of mdnsSnap) {
        if (!subnet.ipInAnySubnet(ip, ifaces) || selfIps.has(ip)) continue;
        const k = get(ip); k.mdns = m; k.alive = true; k.via.add('mdns');
      }
      for (const [ip, m] of this.multisync.seen) {
        if (!subnet.ipInAnySubnet(ip, ifaces) || selfIps.has(ip)) continue;
        const k = get(ip); k.multisync = m; k.alive = true; k.via.add('multisync');
      }
      // Only hosts we actually have evidence for (TCP reply, ARP entry, mDNS, multisync).
      const hosts = [...known.values()].filter((h) => h.alive || h.mac);
      for (const h of hosts) {
        const ifc = ifaces.find((i) => subnet.ipInSubnet(h.ip, i));
        if (ifc) { h.ifaceName = ifc.name; h.network = ifc.cidr; }
      }

      // ---- 4. port scan
      let pdone = 0;
      this._progress('ports', 0, hosts.length);
      await mapLimit(hosts, this.opts.portHostConcurrency, async (h) => {
        const r = await scanPorts(h.ip, COMMON_PORTS.map((p) => p[0]), { timeout: this.opts.portTimeout, concurrency: 8 });
        h.ports = r.open;
        if (r.alive) { h.alive = true; h.via.add('tcp'); }
        this._progress('ports', ++pdone, hosts.length);
      });

      // ---- 5. FPP probe (read-only GETs)
      const web = hosts.filter((h) => (h.ports || []).some((p) => p.port === 80) || h.mdns || h.multisync);
      let fdone = 0;
      this._progress('fpp', 0, web.length);
      await mapLimit(web, this.opts.fppConcurrency, async (h) => {
        const hasWeb = (h.ports || []).some((p) => p.port === 80);
        const likely = !!(h.multisync || (h.mdns && h.mdns.services.some((s) => s.type === '_fppd._udp.local')));
        if (hasWeb || likely) {
          try { h.fpp = await probeFpp(h.ip, { timeout: this.opts.fppTimeout }); } catch (e) { h.fpp = null; }
        }
        this._progress('fpp', ++fdone, web.length);
      });

      // ---- 6. names for anything still unnamed
      const unnamed = hosts.filter((h) => !this._bestName(h));
      for (const h of unnamed) this.mdns.queryReverse(h.ip);
      if (unnamed.length) await sleep(400);
      const rev = this.mdns.snapshot();
      await mapLimit(unnamed, 8, async (h) => {
        const m = rev.get(h.ip);
        if (m && m.hostnames.length) { h.mdns = m; return; }
        const r = await withTimeout(new Promise((res) => dns.reverse(h.ip, (e, names) => res(e ? null : names))), this.opts.nameTimeout);
        if (r && r.length) h.dnsName = r[0];
      });

      // ---- 7. merge with history
      const result = this._merge(hosts, started);
      result.warnings = warnings;
      this.last = result;
      this.emit('done', result);
      return result;
    } catch (e) {
      this.emit('error', e);
      throw e;
    } finally {
      this.running = false;
    }
  }

  _bestName(h) {
    if (h.fpp && h.fpp.hostname) return { name: h.fpp.hostname, source: 'fpp' };
    if (h.mdns && h.mdns.hostnames.length) {
      const n = h.mdns.hostnames.find((x) => x.endsWith('.local')) || h.mdns.hostnames[0];
      return { name: n, source: 'mdns' };
    }
    if (h.multisync && h.multisync.hostname) return { name: h.multisync.hostname, source: 'multisync' };
    if (h.resolvedName && h.alive) return { name: h.resolvedName, source: 'dns-local' };
    if (h.arpName) return { name: h.arpName, source: 'arp' };
    if (h.dnsName) return { name: h.dnsName, source: 'dns' };
    return null;
  }

  _merge(hosts, started) {
    const now = Date.now();
    const prevScan = this.state.lastScan;
    const baseline = !!prevScan; // very first scan: nothing is flagged NEW
    const devices = this.state.devices;
    const seenKeys = new Set();
    for (const h of hosts) {
      let mac = normalizeMac(h.mac);
      let macSource = mac ? 'arp' : null;
      if (!mac && h.fpp) { // FPP reports its own MACs: works even when the OS hides the ARP table
        const ifc = (h.fpp.interfaces || []).find((i) => (i.addrs || []).includes(h.ip));
        if (ifc && normalizeMac(ifc.mac)) { mac = normalizeMac(ifc.mac); macSource = 'fpp'; }
      }
      const key = mac || `ip:${h.ip}`;
      seenKeys.add(key);
      const nm = this._bestName(h);
      const prev = devices[key];
      // A device that previously had no MAC key (ip:...) but now has one inherits its history.
      const legacy = mac && devices[`ip:${h.ip}`];
      const first = (prev && prev.firstSeen) || (legacy && legacy.firstSeen) || now;
      if (legacy) delete devices[`ip:${h.ip}`];
      const fppSummary = h.fpp || null;
      devices[key] = {
        key, mac, macSource, ip: h.ip,
        hostname: nm ? nm.name : (prev && prev.hostname) || null,
        hostnameSource: nm ? nm.source : null,
        vendor: mac ? lookupVendor(mac) : null,
        ports: h.ports || [],
        services: h.mdns ? h.mdns.services.map((s) => ({ type: s.type, port: s.port })) : [],
        fpp: fppSummary || (h.alive && prev && prev.fpp && !h.fpp && (h.ports || []).length === 0 ? prev.fpp : null),
        iface: h.ifaceName || null,
        network: h.network || null,
        via: [...h.via],
        firstSeen: first,
        lastSeen: now,
        lastFpp: fppSummary ? now : (prev && prev.lastFpp) || null,
      };
    }
    this.state.lastScan = { started, ended: now };
    store.prune(this.state, now);
    if (this.storeFile) store.save(this.storeFile, this.state);

    const out = [];
    for (const d of Object.values(devices)) {
      const online = seenKeys.has(d.key);
      if (!online && now - d.lastSeen > this.opts.offlineRetainMs) continue;
      out.push({
        ...d,
        online,
        isFpp: !!d.fpp,
        isNew: online && baseline && d.firstSeen >= prevScan.ended - 1000 && d.firstSeen >= prevScan.started,
        confidence: !online ? 'offline' : (d.via.includes('tcp') || d.via.includes('mdns') || d.via.includes('multisync')) ? 'live' : 'arp-only',
      });
    }
    sortDevices(out);
    return { started, ended: now, interfaces: subnet.activeInterfaces(this.netifs()).map((i) => ({ name: i.name, ip: i.ip, cidr: i.cidr, linkLocal: i.linkLocal })), devices: out, firstRun: !baseline };
  }
}

// Default order: online first, then most recently seen, then newest first-seen.
function sortDevices(list, { pinFpp = false } = {}) {
  list.sort((a, b) => {
    if (pinFpp && a.isFpp !== b.isFpp) return a.isFpp ? -1 : 1;
    if (a.online !== b.online) return a.online ? -1 : 1;
    if (b.lastSeen !== a.lastSeen) return b.lastSeen - a.lastSeen;
    if (b.firstSeen !== a.firstSeen) return b.firstSeen - a.firstSeen;
    return (subnet.ipToInt(a.ip) || 0) - (subnet.ipToInt(b.ip) || 0);
  });
  return list;
}

module.exports = { Scanner, sortDevices, DEFAULTS };
