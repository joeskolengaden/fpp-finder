#!/usr/bin/env node
'use strict';
// Builds src/core/oui-data.json from the IEEE MA-L registry CSV (public data).
// Usage: node scripts/build-oui.js path/to/oui.csv
// Download once with:  curl -o oui.csv https://standards-oui.ieee.org/oui/oui.csv
const fs = require('fs');
const path = require('path');
const { shortenVendor } = require('../src/core/oui');

function parseCsvLine(line) {
  const out = [];
  let cur = '', q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === ',') { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out;
}

const src = process.argv[2];
if (!src) { console.error('usage: build-oui.js oui.csv'); process.exit(1); }
const lines = fs.readFileSync(src, 'utf8').split(/\r?\n/);
const names = [];
const nameIdx = new Map();
const map = {};
for (const line of lines.slice(1)) {
  if (!line.startsWith('MA-L,')) continue;
  const f = parseCsvLine(line);
  const prefix = (f[1] || '').toUpperCase();
  const name = shortenVendor(f[2] || '');
  if (!/^[0-9A-F]{6}$/.test(prefix) || !name) continue;
  let i = nameIdx.get(name);
  if (i === undefined) { i = names.length; names.push(name); nameIdx.set(name, i); }
  map[prefix] = i;
}
const outFile = path.join(__dirname, '..', 'src', 'core', 'oui-data.json');
fs.writeFileSync(outFile, JSON.stringify({ source: 'IEEE MA-L', count: Object.keys(map).length, names, map }));
console.log(`wrote ${outFile}: ${Object.keys(map).length} prefixes, ${names.length} vendors`);
