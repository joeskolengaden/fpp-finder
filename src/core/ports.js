'use strict';
const net = require('net');

const COMMON_PORTS = [
  [22, 'ssh'], [23, 'telnet'], [53, 'dns'], [80, 'http'], [139, 'netbios'], [443, 'https'],
  [445, 'smb'], [554, 'rtsp'], [1883, 'mqtt'], [3389, 'rdp'], [5000, 'upnp/http'],
  [8000, 'http-alt'], [8080, 'http-alt'], [8081, 'http-alt'], [8443, 'https-alt'], [9100, 'printer'],
];
const PORT_NAMES = new Map(COMMON_PORTS);

// Resolves 'open' | 'closed' (RST: host is alive) | 'filtered' (no answer / unreachable)
function tcpProbe(ip, port, timeout = 600) {
  return new Promise((resolve) => {
    let done = false;
    const s = new net.Socket();
    const finish = (r) => { if (!done) { done = true; s.destroy(); resolve(r); } };
    s.setTimeout(timeout, () => finish('filtered'));
    s.once('connect', () => finish('open'));
    s.once('error', (e) => finish(e && e.code === 'ECONNREFUSED' ? 'closed' : 'filtered'));
    try { s.connect({ host: ip, port }); } catch (e) { finish('filtered'); }
  });
}

// Run fn over items with at most `limit` in flight.
async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const workers = [];
  const n = Math.max(1, Math.min(limit, items.length));
  for (let w = 0; w < n; w++) {
    workers.push((async () => {
      while (true) {
        const i = next++;
        if (i >= items.length) return;
        try { results[i] = await fn(items[i], i); } catch (e) { results[i] = undefined; }
      }
    })());
  }
  await Promise.all(workers);
  return results;
}

async function scanPorts(ip, ports = COMMON_PORTS.map((p) => p[0]), { timeout = 600, concurrency = 8 } = {}) {
  const res = await mapLimit(ports, concurrency, (p) => tcpProbe(ip, p, timeout));
  const open = [];
  let alive = false;
  ports.forEach((p, i) => {
    if (res[i] === 'open') { open.push({ port: p, name: PORT_NAMES.get(p) || '' }); alive = true; }
    else if (res[i] === 'closed') alive = true;
  });
  return { open, alive };
}

module.exports = { COMMON_PORTS, PORT_NAMES, tcpProbe, scanPorts, mapLimit };
