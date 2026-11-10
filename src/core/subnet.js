'use strict';
// Pure IPv4 / interface helpers. No I/O.

function ipToInt(ip) {
  const p = String(ip).split('.').map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
  return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3];
}
function intToIp(n) {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.');
}
function prefixFromNetmask(mask) {
  const n = ipToInt(mask);
  if (n === null) return null;
  let bits = 0, seenZero = false;
  for (let i = 31; i >= 0; i--) {
    if ((n >>> i) & 1) { if (seenZero) return null; bits++; } else seenZero = true;
  }
  return bits;
}
function maskInt(prefix) { return prefix === 0 ? 0 : ((0xffffffff << (32 - prefix)) >>> 0); }
function isLinkLocal(ip) { return /^169\.254\./.test(ip); }
function isPrivateOrLinkLocal(ip) {
  return /^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip);
}

// netifs: result of os.networkInterfaces()
function activeInterfaces(netifs) {
  const out = [];
  for (const [name, addrs] of Object.entries(netifs || {})) {
    for (const a of addrs || []) {
      if (!(a.family === 'IPv4' || a.family === 4)) continue;
      if (a.internal) continue;
      const prefix = prefixFromNetmask(a.netmask);
      const ipInt = ipToInt(a.address);
      if (prefix === null || ipInt === null || prefix < 8 || prefix > 30) continue;
      if (/^127\./.test(a.address) || /^0\./.test(a.address)) continue;
      const mask = maskInt(prefix);
      const network = (ipInt & mask) >>> 0;
      out.push({
        name,
        ip: a.address,
        netmask: a.netmask,
        prefix,
        mac: a.mac || null,
        network: intToIp(network),
        broadcast: intToIp((network | (~mask >>> 0)) >>> 0),
        cidr: `${intToIp(network)}/${prefix}`,
        linkLocal: isLinkLocal(a.address),
        hostCount: Math.pow(2, 32 - prefix) - 2,
      });
    }
  }
  return out;
}

function ipInSubnet(ip, iface) {
  const n = ipToInt(ip);
  if (n === null) return false;
  const mask = maskInt(iface.prefix);
  return ((n & mask) >>> 0) === ipToInt(iface.network);
}
function ipInAnySubnet(ip, ifaces) { return ifaces.some((i) => ipInSubnet(ip, i)); }

// The sweep targets for one interface.
//  - subnets up to maxHosts addresses (default /22 = 1022): every host.
//  - larger subnets (e.g. link-local 169.254.0.0/16): only the /24 around our own
//    address, plus `extraIps` (ARP-table / mDNS / previously-seen hosts in the subnet).
//    Never sweeps outside the interface's own subnet.
function enumerateTargets(iface, { maxHosts = 1022, extraIps = [] } = {}) {
  const net = ipToInt(iface.network);
  const self = ipToInt(iface.ip);
  const seen = new Set();
  const out = [];
  const add = (n) => {
    if (n === self || seen.has(n)) return;
    seen.add(n); out.push(intToIp(n));
  };
  if (iface.hostCount <= maxHosts) {
    const bcast = ipToInt(iface.broadcast);
    for (let n = net + 1; n < bcast; n++) add(n);
  } else {
    const base = (self & 0xffffff00) >>> 0;
    for (let n = base + 1; n < base + 255; n++) {
      if (ipInSubnet(intToIp(n), iface)) add(n);
    }
  }
  for (const ip of extraIps) {
    const n = ipToInt(ip);
    if (n !== null && ipInSubnet(ip, iface) && n !== ipToInt(iface.broadcast) && n !== net) add(n);
  }
  return out;
}

module.exports = {
  ipToInt, intToIp, prefixFromNetmask, maskInt, isLinkLocal, isPrivateOrLinkLocal,
  activeInterfaces, ipInSubnet, ipInAnySubnet, enumerateTargets,
};
