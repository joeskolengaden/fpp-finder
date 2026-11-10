'use strict';
// OUI (MAC vendor) lookup against a bundled IEEE MA-L table (src/core/oui-data.json).
// Fully offline. A few curated overrides give friendlier names for the vendors
// that matter for FPP setups.

const MAC_RE = /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/;

// Friendly names for vendors that matter in FPP setups (applied to IEEE names).
// Raspberry Pi, BeagleBoard/TI, Espressif (ESP32/ESP8266 pixel controllers),
// Ubiquiti and the common router vendors.
const FRIENDLY = [
  [/^raspberry pi/i, 'Raspberry Pi'],
  [/^texas instruments/i, 'Texas Instruments'],
  [/beagle/i, 'BeagleBoard'],
  [/^espressif/i, 'Espressif'],
  [/^ubiquiti/i, 'Ubiquiti'],
  [/^tp-?link/i, 'TP-Link'],
  [/^netgear/i, 'Netgear'],
  [/^d-?link/i, 'D-Link'],
  [/^asustek|^asus\b/i, 'ASUS'],
  [/^cisco/i, 'Cisco'],
  [/^arris|^commscope|^ruckus/i, null],
  [/^eero/i, 'eero'],
  [/^google/i, 'Google'],
  [/^apple/i, 'Apple'],
  [/^intel/i, 'Intel'],
];

// Normalises noisy IEEE organisation names to short readable ones.
function shortenVendor(name) {
  let n = String(name).replace(/\s+/g, ' ').trim();
  n = n.replace(/[,.]?\s*\b(Co\.?,?\s*Ltd\.?|Corporation|Corp\.?|Inc\.?|Incorporated|Limited|Ltd\.?|LLC|GmbH|S\.?A\.?|B\.?V\.?|Pte\.?|Pty|AG|PLC|Technologies Co)\b\.?/gi, '');
  n = n.replace(/[,\s.]+$/g, '').trim();
  if (!n) n = String(name).trim();
  for (const [re, friendly] of FRIENDLY) { if (friendly && re.test(n)) return friendly; }
  return n.length > 40 ? n.slice(0, 40).trim() : n;
}

let table = null;
function loadTable() {
  if (table) return table;
  try { table = require('./oui-data.json'); }
  catch (e) { table = { names: [], map: {} }; }
  return table;
}

function normalizeMac(mac) {
  if (!mac) return null;
  const parts = String(mac).trim().toLowerCase().split(/[:\-.]/);
  if (parts.length === 3 && parts.every((p) => p.length === 4)) {
    // Cisco dotted notation aabb.ccdd.eeff
    const hex = parts.join('');
    return hex.match(/.{2}/g).join(':');
  }
  if (parts.length !== 6) return null;
  const out = parts.map((p) => (p.length === 1 ? '0' + p : p));
  if (!out.every((p) => /^[0-9a-f]{2}$/.test(p))) return null;
  return out.join(':');
}

function isMulticastOrBroadcastMac(mac) {
  const m = normalizeMac(mac);
  if (!m) return true;
  if (m === 'ff:ff:ff:ff:ff:ff' || m === '00:00:00:00:00:00') return true;
  return (parseInt(m.slice(0, 2), 16) & 1) === 1; // group bit => multicast
}

// Locally administered MACs (randomised phone MACs, VMs) have no vendor.
function isLocallyAdministered(mac) {
  const m = normalizeMac(mac);
  return !!m && (parseInt(m.slice(0, 2), 16) & 2) === 2;
}

function lookupVendor(mac) {
  const m = normalizeMac(mac);
  if (!m) return null;
  const prefix = m.slice(0, 8).replace(/:/g, '').toUpperCase();
  const t = loadTable();
  const idx = t.map[prefix];
  if (idx !== undefined) return t.names[idx];
  if (isLocallyAdministered(m)) return 'Private (randomised MAC)';
  return null;
}

module.exports = { lookupVendor, normalizeMac, isMulticastOrBroadcastMac, isLocallyAdministered, shortenVendor, MAC_RE };
