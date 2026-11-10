'use strict';
// Parsers + runner for the OS ARP table (`arp -a`), macOS / Linux / Windows.
const { execFile } = require('child_process');
const { normalizeMac, isMulticastOrBroadcastMac } = require('./oui');

const IPV4 = '(\\d{1,3}(?:\\.\\d{1,3}){3})';
// macOS / BSD / Linux (net-tools):  host.local (169.254.9.67) at 4:23:22:aa:bb:cc on en5 [ethernet]
const UNIX_RE = new RegExp('^\\s*(\\S+)\\s+\\(' + IPV4 + '\\)\\s+at\\s+(\\S+)(.*)$');
// Windows:  192.168.1.1           aa-bb-cc-dd-ee-ff     dynamic
const WIN_RE = new RegExp('^\\s*' + IPV4 + '\\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})\\s+(\\S+)\\s*$');
// Windows interface header (localised word before the colon):  Interface: 192.168.1.10 --- 0x4
const WIN_IFACE_RE = new RegExp('^\\s*[^\\d\\s][^:]*:\\s+' + IPV4 + '\\s+---\\s+0x[0-9a-fA-F]+');

function parseArp(text) {
  const entries = [];
  let winIface = null;
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, '');
    if (!line) continue;

    const wi = WIN_IFACE_RE.exec(line);
    if (wi) { winIface = wi[1]; continue; }

    let m = UNIX_RE.exec(line);
    if (m) {
      const [, name, ip, macRaw, rest] = m;
      const im = /\bon\s+(\S+)/.exec(rest || '');
      const iface = im ? im[1] : null;
      if (/incomplete/i.test(macRaw)) continue;
      const mac = normalizeMac(macRaw);
      if (!mac) continue;
      entries.push({
        ip,
        mac,
        hostname: name === '?' ? null : name,
        iface: iface || null,
        permanent: /permanent/i.test(rest || ''),
        type: /permanent|static/i.test(rest || '') ? 'static' : 'dynamic',
      });
      continue;
    }

    m = WIN_RE.exec(line);
    if (m) {
      const mac = normalizeMac(m[2]);
      if (!mac) continue;
      entries.push({ ip: m[1], mac, hostname: null, iface: winIface, permanent: false, type: m[3].toLowerCase() });
    }
  }
  return entries;
}

// IPs that are never unicast hosts we want to list.
function isUsableArpEntry(e) {
  if (isMulticastOrBroadcastMac(e.mac)) return false;
  const first = parseInt(e.ip.split('.')[0], 10);
  if (first >= 224) return false; // multicast / reserved
  if (e.ip.endsWith('.255')) return false;
  return true;
}

// Returns {entries, rawCount}. rawCount === 0 means the OS gave us nothing at all (not even our
// own permanent entries) - on macOS that is what a denied "Local Network" privacy prompt looks like.
function readArpTable({ timeout = 4000 } = {}) {
  return new Promise((resolve) => {
    // `arp -a` exists on macOS, Linux (net-tools) and Windows. No shell is used.
    // Numeric (-n) on unix: plain `arp -a` reverse-resolves every entry and can stall for
    // seconds per host with no DNS. Windows `arp -a` is always numeric.
    const args = process.platform === 'win32' ? ['-a'] : ['-an'];
    execFile('arp', args, { timeout, windowsHide: true, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      if (err && !stdout) return resolve({ entries: [], rawCount: 0 });
      const all = parseArp(stdout);
      resolve({ entries: all.filter(isUsableArpEntry), rawCount: all.length });
    });
  });
}

module.exports = { parseArp, readArpTable, isUsableArpEntry };
