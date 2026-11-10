'use strict';
// FPP (Falcon Player) detection. classify*() functions are pure; probeFpp() does
// read-only HTTP GETs with short timeouts. Nothing here ever writes to a device.
const http = require('http');

function safeJson(body) {
  if (body && typeof body === 'object') return body;
  const text = String(body == null ? '' : body);
  try { return JSON.parse(text); } catch (e) { /* fall through */ }
  // FPP 5.x's PHP can print "<b>Notice</b>: ..." HTML before the JSON payload; skip to the JSON.
  const m = /[\[{]/.exec(text);
  if (m && m.index > 0) { try { return JSON.parse(text.slice(m.index)); } catch (e) { /* not JSON */ } }
  return null;
}

// GET /api/fppd/version  ->  {"fppdAPI":"v1","version":"5.4.1","branch":"v5.4","majorVersion":"5","minorVersion":"4",...}
function classifyVersion(body) {
  const j = safeJson(body);
  if (!j || typeof j !== 'object' || Array.isArray(j)) return { isFpp: false };
  const hasApi = typeof j.fppdAPI === 'string';
  const hasVer = typeof j.version === 'string' && ('branch' in j || 'majorVersion' in j);
  if (!hasApi && !hasVer) return { isFpp: false };
  return {
    isFpp: true,
    version: j.version != null ? String(j.version) : null,
    branch: j.branch != null ? String(j.branch) : null,
    major: j.majorVersion != null ? Number(j.majorVersion) : null,
    minor: j.minorVersion != null ? Number(j.minorVersion) : null,
  };
}

const MODE_NUM = { 1: 'bridge', 2: 'player', 6: 'player', 8: 'remote' };

// GET /api/fppd/status
function classifyStatus(body) {
  const j = safeJson(body);
  if (!j || typeof j !== 'object') return null;
  let mode = typeof j.mode_name === 'string' && j.mode_name ? j.mode_name : (MODE_NUM[j.mode] || null);
  if (mode === 'master') mode = 'player';
  return {
    fppd: j.fppd || null,
    mode,
    bridging: j.bridging === true || j.bridging === 1,
    multisync: j.multisync === true || j.multisync === 1,
    status: j.status_name || null,
    uptime: j.uptime || null,
    playlist: j.current_playlist && j.current_playlist.playlist ? j.current_playlist.playlist : null,
    sequence: j.current_sequence || null,
  };
}

function platformFamily(text) {
  const s = String(text || '');
  if (/beagle|am33|bbb|bbg|pocketbeagle|\bti\b/i.test(s)) return 'BeagleBone';
  if (/raspberry|\brpi\b|\bpi ?(zero|[0-9])|bcm2/i.test(s)) return 'Raspberry Pi';
  if (/docker|container/i.test(s)) return 'Docker';
  if (/linux|debian|ubuntu|x86|amd64/i.test(s)) return 'Linux';
  if (/mac|darwin/i.test(s)) return 'macOS';
  return s || null;
}

// GET /api/fppd/multiSyncSystems  -> {systems:[{address,hostname,model,type,version,local:1,fppModeString,...}]}
function classifyMultiSync(body, ip) {
  const j = safeJson(body);
  if (!j || !Array.isArray(j.systems)) return null;
  const sys = j.systems.find((s) => s && s.local) || j.systems.find((s) => s && s.address === ip) || null;
  if (!sys) return null;
  return {
    hostname: sys.hostname || null,
    model: sys.model || null,
    type: sys.type || null,
    version: sys.version || null,
    mode: sys.fppModeString || null,
    platform: platformFamily(`${sys.model || ''} ${sys.type || ''}`),
    // other FPP units this device knows about (multisync peers)
    peers: j.systems.filter((s) => s && s !== sys && s.address).map((s) => ({
      address: s.address, hostname: s.hostname || null, version: s.version || null, type: s.type || null,
    })),
  };
}

// GET /api/system/info  (newer FPP only; 404 page on 5.4)
function classifySystemInfo(body) {
  const j = safeJson(body);
  if (!j || typeof j !== 'object' || (!j.Platform && !j.HostName && !j.Variant)) return null;
  return {
    hostname: j.HostName || null,
    description: j.HostDescription || null,
    platform: platformFamily(`${j.Platform || ''} ${j.Variant || ''}`),
    model: j.Variant || j.Platform || null,
    osVersion: j.OSVersion || null,
    version: j.Version || null,
    mode: j.Mode || null,
  };
}

// GET /api/plugin -> ["a","b"] (5.4) or [{"name":..}] in other versions
function classifyPlugins(body) {
  const j = safeJson(body);
  if (!Array.isArray(j)) return [];
  return j.map((p) => (typeof p === 'string' ? p : (p && (p.name || p.repoName || p.id)) || null)).filter(Boolean);
}

// GET /api/network/interface -> [{ifname, address(MAC), addr_info:[{local}]}]
function classifyInterfaces(body) {
  const j = safeJson(body);
  if (!Array.isArray(j)) return [];
  return j.filter((i) => i && i.ifname && i.ifname !== 'lo').map((i) => ({
    name: i.ifname,
    mac: i.address || null,
    state: i.operstate || null,
    addrs: (i.addr_info || []).filter((a) => a.family === 'inet').map((a) => a.local),
  }));
}

// Merge probe results into one device-level FPP descriptor.
function buildFppInfo({ ip, version, status, multisync, sysinfo, plugins, interfaces }) {
  if (!version || !version.isFpp) return null;
  const mode = (status && status.mode) || (multisync && multisync.mode) || (sysinfo && sysinfo.mode) || null;
  const platform = (multisync && multisync.platform) || (sysinfo && sysinfo.platform) || null;
  return {
    version: version.version || (multisync && multisync.version) || null,
    branch: version.branch,
    mode,
    modeLabel: mode ? (status && status.bridging && mode === 'player' ? 'player + bridge' : mode) : null,
    platform,
    model: (multisync && multisync.model) || (sysinfo && sysinfo.model) || null,
    hostname: (multisync && multisync.hostname) || (sysinfo && sysinfo.hostname) || null,
    description: (sysinfo && sysinfo.description) || null,
    fppd: status ? status.fppd : null,
    state: status ? status.status : null,
    uptime: status ? status.uptime : null,
    playlist: status ? status.playlist : null,
    sequence: status ? status.sequence : null,
    multisync: status ? status.multisync : false,
    plugins: plugins || [],
    peers: multisync ? multisync.peers : [],
    interfaces: interfaces || [],
    url: `http://${ip}/`,
  };
}

// Read-only GET with hard timeout and body cap. Resolves {status, body} or null.
function httpGet(ip, path, { port = 80, timeout = 1500, maxBytes = 512 * 1024 } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    const req = http.request({
      host: ip, port, path, method: 'GET', agent: false, timeout,
      headers: { Accept: 'application/json', Connection: 'close', 'User-Agent': 'fpp-finder/1 (read-only probe)' },
    }, (res) => {
      const chunks = [];
      let size = 0;
      res.on('data', (c) => {
        size += c.length;
        if (size > maxBytes) { req.destroy(); return finish(null); }
        chunks.push(c);
      });
      res.on('end', () => finish({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', () => finish(null));
    });
    req.on('timeout', () => { req.destroy(); finish(null); });
    req.on('error', () => finish(null));
    const hard = setTimeout(() => { req.destroy(); finish(null); }, timeout + 500);
    req.on('close', () => clearTimeout(hard));
    req.end();
  });
}

// Probe one host. Returns null if it is not FPP.
async function probeFpp(ip, { port = 80, timeout = 1500 } = {}) {
  const get = (p) => httpGet(ip, p, { port, timeout });
  const v = await get('/api/fppd/version');
  if (!v || v.status !== 200) return null;
  const version = classifyVersion(v.body);
  if (!version.isFpp) return null;
  const [st, ms, si, pl, ni] = await Promise.all([
    get('/api/fppd/status'), get('/api/fppd/multiSyncSystems'), get('/api/system/info'),
    get('/api/plugin'), get('/api/network/interface'),
  ]);
  return buildFppInfo({
    ip,
    version,
    status: st && st.status === 200 ? classifyStatus(st.body) : null,
    multisync: ms && ms.status === 200 ? classifyMultiSync(ms.body, ip) : null,
    sysinfo: si && si.status === 200 ? classifySystemInfo(si.body) : null,
    plugins: pl && pl.status === 200 ? classifyPlugins(pl.body) : [],
    interfaces: ni && ni.status === 200 ? classifyInterfaces(ni.body) : [],
  });
}

module.exports = {
  classifyVersion, classifyStatus, classifyMultiSync, classifySystemInfo, classifyPlugins,
  classifyInterfaces, buildFppInfo, platformFamily, httpGet, probeFpp,
};
