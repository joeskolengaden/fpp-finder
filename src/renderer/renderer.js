'use strict';
const $ = (id) => document.getElementById(id);
let result = null;
let scanning = false;
const ui = { fppOnly: false, pinFpp: true, showOffline: true, q: '', sortKey: 'lastSeen', sortDir: -1 };

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

function ago(ts) {
  const s = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (s < 8) return 'just now';
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
const full = (ts) => new Date(ts).toLocaleString();
const ipNum = (ip) => ip.split('.').reduce((a, b) => a * 256 + Number(b), 0);

function visibleDevices() {
  if (!result) return [];
  const q = ui.q.trim().toLowerCase();
  let list = result.devices.filter((d) => {
    if (ui.fppOnly && !d.isFpp) return false;
    if (!ui.showOffline && !d.online) return false;
    if (q) {
      const hay = [d.ip, d.hostname, d.mac, d.vendor, d.fpp && d.fpp.version, d.fpp && d.fpp.platform, d.isFpp ? 'fpp' : ''].join(' ').toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
  const key = ui.sortKey, dir = ui.sortDir;
  const val = (d) => key === 'ip' ? ipNum(d.ip) : (d[key] == null ? '' : d[key]);
  list = list.slice().sort((a, b) => {
    if (ui.pinFpp && a.isFpp !== b.isFpp) return a.isFpp ? -1 : 1;
    if (a.online !== b.online && key === 'lastSeen') return a.online ? -1 : 1;
    const x = val(a), y = val(b);
    if (x < y) return -dir; if (x > y) return dir;
    return b.lastSeen - a.lastSeen;
  });
  return list;
}

function fppInfo(d) {
  const f = d.fpp;
  const bits = [
    h('span', { class: 'badge fpp' }, 'FPP'),
    h('span', {}, 'version ', h('b', {}, f.version || '?')),
    f.mode && h('span', {}, 'mode ', h('b', {}, f.modeLabel || f.mode)),
    f.platform && h('span', {}, 'platform ', h('b', {}, f.platform + (f.model && !f.model.includes(f.platform) ? ` (${f.model})` : ''))),
    f.hostname && h('span', {}, 'host ', h('b', {}, f.hostname)),
    f.state && h('span', { class: 'muted' }, `status: ${f.state}`),
    f.uptime && h('span', { class: 'muted' }, `uptime ${f.uptime}`),
    f.playlist && f.sequence && h('span', { class: 'muted' }, `playing ${f.sequence}`),
  ];
  const plugins = f.plugins.length
    ? [h('span', { class: 'muted' }, `plugins (${f.plugins.length}):`), ...f.plugins.map((p) => h('span', { class: 'plug' }, p))]
    : [h('span', { class: 'muted' }, 'plugins: none installed')];
  return h('div', { class: 'fppline' }, bits, plugins);
}

function render() {
  const body = $('rows');
  body.replaceChildren();
  const list = visibleDevices();
  $('empty').hidden = list.length > 0;
  for (const d of list) {
    const flags = h('td', { class: 'c-flags' },
      d.isFpp && h('span', { class: 'badge fpp' }, 'FPP'),
      d.isNew && h('span', { class: 'badge new' }, 'NEW'),
      !d.online && h('span', { class: 'badge off' }, 'OFFLINE'),
      d.online && d.confidence === 'arp-only' && h('span', { class: 'badge arp', title: 'Listed in the ARP cache but did not answer a probe; may be stale' }, 'ARP'));
    const row = h('tr', { class: `dev${d.isFpp ? ' fpp hasdetail' : ''}${d.online ? '' : ' off'}` },
      flags,
      h('td', { class: 'mono' }, d.ip),
      h('td', {}, d.hostname || h('span', { class: 'muted' }, '—'), d.hostnameSource && d.hostname ? h('span', { class: 'muted' }, ` · ${d.hostnameSource === 'fpp' ? 'FPP API' : d.hostnameSource}`) : null),
      h('td', { class: 'mono' }, d.mac || h('span', { class: 'muted' }, '—')),
      h('td', {}, d.vendor || h('span', { class: 'muted' }, '—')),
      h('td', {}, (d.ports || []).length ? d.ports.map((p) => h('span', { class: 'port', title: p.name }, p.port)) : h('span', { class: 'muted' }, '—')),
      h('td', { title: full(d.firstSeen) }, ago(d.firstSeen)),
      h('td', { title: full(d.lastSeen) }, ago(d.lastSeen)),
      h('td', { class: 'act' },
        d.isFpp && d.online && h('button', { class: 'web', title: `Open http://${d.ip}/ in your browser`, onclick: () => window.finder.openWeb(d.ip) }, 'Open web UI'),
        !d.isFpp && d.online && (d.ports || []).some((p) => p.port === 80) && h('button', { title: `Open http://${d.ip}/`, onclick: () => window.finder.openWeb(d.ip) }, 'Open'),
        h('button', { title: 'Copy IP address', onclick: (e) => { window.finder.copy(d.ip); const b = e.currentTarget; const t = b.textContent; b.textContent = 'Copied ✓'; setTimeout(() => { b.textContent = t; }, 1100); } }, 'Copy IP')));
    body.append(row);
    if (d.isFpp) body.append(h('tr', { class: 'detail fpp' }, h('td', {}), h('td', { colspan: 8 }, fppInfo(d))));
  }
  renderStatus();
}

function renderStatus() {
  if (!result) return;
  const w = $('warn');
  const arpWarn = (result.warnings || []).includes('arp-empty');
  w.hidden = !arpWarn;
  if (arpWarn) w.textContent = window.finder.platform === 'darwin'
    ? 'The OS returned an empty ARP table, so MAC addresses and link-local devices may be missing. On macOS, allow FPP Finder under System Settings → Privacy & Security → Local Network, then Rescan.'
    : 'The OS returned an empty ARP table, so MAC addresses may be missing.';
  const online = result.devices.filter((d) => d.online);
  const fpp = online.filter((d) => d.isFpp).length;
  const nw = result.devices.filter((d) => d.isNew).length;
  const parts = [`${online.length} online`, `${fpp} FPP`, nw ? `${nw} new` : null, `last scan ${ago(result.ended)}`].filter(Boolean);
  if (!scanning) $('statusText').textContent = parts.join(' · ');
  $('ifaces').replaceChildren(...result.interfaces.map((i) => h('span', { class: `chip${i.linkLocal ? ' ll' : ''}`, title: i.linkLocal ? 'Link-local (169.254.x.x) network' : '' }, `${i.name} · ${i.ip} · ${i.cidr}`)));
}

function setScanning(on) {
  scanning = on;
  $('rescan').disabled = on;
  $('rescan').textContent = on ? 'Scanning…' : 'Rescan';
  $('bar').classList.toggle('on', on);
  if (!on) { $('barFill').style.width = '0'; renderStatus(); }
}
const STAGES = { start: 'Starting', sweep: 'Sweeping network', ports: 'Scanning ports', fpp: 'Probing for FPP', };
function onProgress(p) {
  $('statusText').textContent = `${STAGES[p.stage] || p.stage}${p.total ? ` (${p.done}/${p.total})` : ''}…`;
  const order = ['sweep', 'ports', 'fpp'];
  const i = Math.max(0, order.indexOf(p.stage));
  const frac = p.total ? p.done / p.total : 0;
  $('barFill').style.width = `${Math.round(((i + frac) / order.length) * 100)}%`;
}

async function init() {
  const st = await window.finder.getState();
  $('interval').value = String(st.settings.intervalSec);
  result = st.result;
  setScanning(st.scanning);
  if (st.progress) onProgress(st.progress);
  window.finder.onStart(() => setScanning(true));
  window.finder.onProgress(onProgress);
  window.finder.onDone((r) => { result = r; setScanning(false); render(); });
  window.finder.onError((m) => { setScanning(false); $('statusText').textContent = `Scan error: ${m}`; });
  render();

  $('rescan').addEventListener('click', () => window.finder.scan());
  $('interval').addEventListener('change', (e) => window.finder.setSettings({ intervalSec: Number(e.target.value) }));
  $('fppOnly').addEventListener('change', (e) => { ui.fppOnly = e.target.checked; render(); });
  $('pinFpp').addEventListener('change', (e) => { ui.pinFpp = e.target.checked; render(); });
  $('showOffline').addEventListener('change', (e) => { ui.showOffline = e.target.checked; render(); });
  $('search').addEventListener('input', (e) => { ui.q = e.target.value; render(); });
  document.querySelectorAll('th[data-sort]').forEach((th) => th.addEventListener('click', () => {
    const k = th.dataset.sort;
    if (ui.sortKey === k) ui.sortDir *= -1; else { ui.sortKey = k; ui.sortDir = (k === 'lastSeen' || k === 'firstSeen') ? -1 : 1; }
    document.querySelectorAll('th[data-sort]').forEach((x) => { x.classList.remove('sorted'); x.textContent = x.textContent.replace(/ [▴▾]$/, ''); });
    th.classList.add('sorted'); th.textContent += ui.sortDir < 0 ? ' ▾' : ' ▴';
    render();
  }));
  setInterval(render, 10000); // keep relative times fresh
}
init();
