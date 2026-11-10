'use strict';
// Minimal mDNS/Bonjour browser built on `multicast-dns` (pure JS). One socket per
// active IPv4 interface so link-local (169.254.x.x) links are covered too.
// Only sends standard read-only DNS queries and listens for answers.
const mdnsLib = require('multicast-dns');

// Service types worth asking about. FPP 5.x/6+ advertises `_fppd._udp` (port 32320)
// and `_http._tcp` via avahi; `_wled._tcp` helps spot WLED/ESP pixel controllers.
const SERVICE_TYPES = ['_fppd._udp.local', '_http._tcp.local', '_wled._tcp.local', '_ssh._tcp.local', '_workstation._tcp.local', '_device-info._tcp.local'];
const ENUM_NAME = '_services._dns-sd._udp.local';

function dataToString(d) { return Buffer.isBuffer(d) ? d.toString('utf8') : String(d); }

class MdnsBrowser {
  constructor({ log = () => {} } = {}) {
    this.log = log;
    this.sockets = [];
    this.hostToIps = new Map();   // 'fpp.local' -> Set(ip)
    this.instances = new Map();   // instance fqdn -> {type, srvTarget, port, txt}
    this.byIp = new Map();        // ip -> {hostnames:Set, services:Map}
    this.reverse = new Map();     // ip -> hostname (from PTR in-addr.arpa)
    this.knownTypes = new Set(SERVICE_TYPES);
  }

  start(ifaces) {
    this.stop();
    for (const ifc of ifaces) {
      try {
        const m = mdnsLib({ interface: ifc.ip, multicast: true, loopback: false, reuseAddr: true, ttl: 255 });
        m.on('response', (pkt, rinfo) => this._onPacket(pkt, rinfo, ifc));
        m.on('error', (e) => this.log(`mdns ${ifc.name}: ${e.message}`));
        this.sockets.push({ m, ifc });
      } catch (e) { this.log(`mdns ${ifc.name}: ${e.message}`); }
    }
  }

  stop() {
    for (const s of this.sockets) { try { s.m.destroy(); } catch (e) { /* ignore */ } }
    this.sockets = [];
  }

  _send(questions) {
    for (const s of this.sockets) {
      try { s.m.query({ questions }, (err) => { if (err) this.log(`mdns send ${s.ifc.name}: ${err.message}`); }); }
      catch (e) { this.log(`mdns send ${s.ifc.name}: ${e.message}`); }
    }
  }

  // Ask for service lists and our favourite FPP names.
  query(extraHostnames = ['fpp.local']) {
    const q = [{ name: ENUM_NAME, type: 'PTR' }];
    for (const t of this.knownTypes) q.push({ name: t, type: 'PTR' });
    for (const h of extraHostnames) q.push({ name: h, type: 'A' });
    this._send(q);
  }

  queryReverse(ip) {
    const name = ip.split('.').reverse().join('.') + '.in-addr.arpa';
    this._send([{ name, type: 'PTR' }]);
  }

  _entry(ip) {
    let e = this.byIp.get(ip);
    if (!e) { e = { hostnames: new Set(), services: new Map() }; this.byIp.set(ip, e); }
    return e;
  }

  _onPacket(pkt, rinfo, ifc) {
    const records = [...(pkt.answers || []), ...(pkt.additionals || [])];
    for (const r of records) {
      const name = String(r.name || '').toLowerCase();
      if (r.type === 'A' && typeof r.data === 'string') {
        if (!this.hostToIps.has(name)) this.hostToIps.set(name, new Set());
        this.hostToIps.get(name).add(r.data);
        this._entry(r.data).hostnames.add(name);
      } else if (r.type === 'PTR') {
        const target = dataToString(r.data);
        if (name === ENUM_NAME) { this.knownTypes.add(target.toLowerCase()); }
        else if (name.endsWith('.in-addr.arpa')) {
          const ip = name.replace('.in-addr.arpa', '').split('.').reverse().join('.');
          this.reverse.set(ip, target.replace(/\.$/, ''));
        } else if (this.knownTypes.has(name)) {
          const inst = this.instances.get(target) || {};
          inst.type = name; inst.instance = target;
          this.instances.set(target, inst);
        }
      } else if (r.type === 'SRV' && r.data) {
        const inst = this.instances.get(r.name) || { instance: r.name };
        inst.srvTarget = String(r.data.target || '').toLowerCase();
        inst.port = r.data.port;
        const m = /\._([a-z0-9-]+\._(?:tcp|udp)\.local)$/i.exec(r.name);
        if (m && !inst.type) inst.type = '_' + m[1].toLowerCase();
        this.instances.set(r.name, inst);
      }
    }
    // The datagram's source IP is a reliable address for the responder.
    if (rinfo && rinfo.address) this._entry(rinfo.address);
    this._rebuild();
  }

  _rebuild() {
    for (const inst of this.instances.values()) {
      if (!inst.srvTarget) continue;
      const ips = this.hostToIps.get(inst.srvTarget);
      if (!ips) continue;
      for (const ip of ips) {
        const e = this._entry(ip);
        e.hostnames.add(inst.srvTarget);
        const key = `${inst.type || '?'}|${inst.instance}`;
        e.services.set(key, { type: inst.type, instance: inst.instance, port: inst.port, host: inst.srvTarget });
      }
    }
  }

  // Snapshot: ip -> {hostnames:[], services:[]}
  snapshot() {
    const out = new Map();
    for (const [ip, e] of this.byIp) {
      const hostnames = [...e.hostnames];
      const rev = this.reverse.get(ip);
      if (rev) hostnames.push(rev.toLowerCase());
      if (!hostnames.length && !e.services.size) continue;
      out.set(ip, { hostnames, services: [...e.services.values()] });
    }
    for (const [ip, rev] of this.reverse) if (!out.has(ip)) out.set(ip, { hostnames: [rev.toLowerCase()], services: [] });
    return out;
  }
}

module.exports = { MdnsBrowser, SERVICE_TYPES };
