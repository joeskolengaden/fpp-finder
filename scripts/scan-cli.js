#!/usr/bin/env node
'use strict';
// Headless scan (no Electron). Usage: node scripts/scan-cli.js [--json] [--store file]
const os = require('os');
const path = require('path');
const { Scanner } = require('../src/core/scanner');

const args = process.argv.slice(2);
const json = args.includes('--json');
const si = args.indexOf('--store');
const seeds = []; args.forEach((a, i) => { if (a === '--seed') seeds.push(args[i + 1]); });
const storeFile = si >= 0 ? args[si + 1] : path.join(os.tmpdir(), 'fpp-finder-cli-store.json');

(async () => {
  const s = new Scanner({ storeFile, options: { seedIps: seeds }, log: (m) => process.stderr.write(`[log] ${m}\n`) });
  const t0 = Date.now();
  const res = await s.scan();
  s.stop();
  if (json) { console.log(JSON.stringify(res, null, 2)); return; }
  console.log(`Interfaces: ${res.interfaces.map((i) => `${i.name} ${i.cidr}`).join(', ')}`);
  if (res.warnings && res.warnings.length) console.log(`WARNINGS: ${res.warnings.join(', ')}`);
  console.log(`Scan took ${((Date.now() - t0) / 1000).toFixed(1)}s, ${res.devices.length} devices\n`);
  for (const d of res.devices) {
    const f = d.fpp ? `  *** FPP ${d.fpp.version} ${d.fpp.mode || ''} ${d.fpp.platform || ''} plugins=[${d.fpp.plugins.join(', ')}]` : '';
    console.log(`${d.isFpp ? 'FPP' : '   '} ${d.isNew ? 'NEW' : '   '} ${d.ip.padEnd(16)} ${String(d.mac).padEnd(18)} ${String(d.hostname || '-').padEnd(20)} ${String(d.vendor || '-').padEnd(24)} ports=${d.ports.map((p) => p.port).join(',')}${f}`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
