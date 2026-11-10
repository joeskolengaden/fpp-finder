'use strict';
// Persists first-seen / last-seen history so "NEW" and first-seen survive restarts.
const fs = require('fs');
const path = require('path');

const RETAIN_MS = 30 * 24 * 3600 * 1000;

function emptyState() { return { version: 1, devices: {}, lastScan: null }; }

function load(file) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (j && j.version === 1 && j.devices) return j;
  } catch (e) { /* first run or corrupt: start fresh */ }
  return emptyState();
}

function save(file, state) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, file);
  } catch (e) { /* history is a convenience; never fail a scan over it */ }
}

function prune(state, now = Date.now()) {
  for (const [k, d] of Object.entries(state.devices)) {
    if (now - (d.lastSeen || 0) > RETAIN_MS) delete state.devices[k];
  }
}

module.exports = { load, save, prune, emptyState, RETAIN_MS };
