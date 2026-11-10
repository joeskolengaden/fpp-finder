'use strict';
const { app, BrowserWindow, ipcMain, shell, clipboard, Menu } = require('electron');
const path = require('path');
const fs = require('fs');
const { Scanner, sortDevices } = require('./core/scanner');

let win = null;
let scanner = null;
let timer = null;
let settings = { intervalSec: 60 };
let lastResult = null;
let progress = null;

const userData = () => app.getPath('userData');
const settingsFile = () => path.join(userData(), 'settings.json');

function loadSettings() {
  try { settings = { ...settings, ...JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) }; } catch (e) { /* defaults */ }
}
function saveSettings() {
  try { fs.mkdirSync(userData(), { recursive: true }); fs.writeFileSync(settingsFile(), JSON.stringify(settings)); } catch (e) { /* ignore */ }
}
const send = (ch, payload) => { if (win && !win.isDestroyed()) win.webContents.send(ch, payload); };

function schedule() {
  clearInterval(timer); timer = null;
  const s = Number(settings.intervalSec) || 0;
  if (s > 0) timer = setInterval(() => runScan(), s * 1000);
}

async function runScan() {
  if (!scanner || scanner.running) return;
  try { await scanner.scan(); } catch (e) { send('scan:error', String(e && e.message || e)); }
}

function createWindow() {
  win = new BrowserWindow({
    width: 1280, height: 780, minWidth: 900, minHeight: 500,
    title: 'FPP Finder',
    backgroundColor: '#0f1419',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true,
    },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  // Never navigate or open windows inside the app.
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.on('closed', () => { win = null; });
}

app.whenReady().then(() => {
  loadSettings();
  const seeds = (process.env.FPP_FINDER_SEEDS || '').split(',').map((x) => x.trim()).filter(Boolean);
  scanner = new Scanner({ storeFile: path.join(userData(), 'devices.json'), options: { seedIps: seeds }, log: (m) => console.log('[scanner]', m) });
  scanner.on('start', (s) => { progress = { stage: 'start', done: 0, total: 0 }; send('scan:start', s); });
  scanner.on('progress', (p) => { progress = p; send('scan:progress', p); });
  scanner.on('done', (r) => { progress = null; lastResult = r; send('scan:done', r); onDone(r); });

  ipcMain.handle('state:get', () => ({ settings, scanning: !!(scanner && scanner.running), progress, result: lastResult, platform: process.platform }));
  ipcMain.handle('scan:run', () => { runScan(); return true; });
  ipcMain.handle('settings:set', (_e, patch) => {
    if (patch && typeof patch.intervalSec === 'number' && [0, 15, 30, 60, 120, 300].includes(patch.intervalSec)) {
      settings.intervalSec = patch.intervalSec; saveSettings(); schedule();
    }
    return settings;
  });
  // Only ever open http://<ip>/ for an IP that is currently in the device list.
  ipcMain.handle('open:web', (_e, ip) => {
    const ok = lastResult && lastResult.devices.some((d) => d.ip === ip);
    if (!ok) return false;
    shell.openExternal(`http://${ip}/`);
    return true;
  });
  ipcMain.handle('copy:text', (_e, text) => { clipboard.writeText(String(text).slice(0, 200)); return true; });

  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []),
    { role: 'editMenu' }, { role: 'viewMenu' }, { role: 'windowMenu' },
  ]));
  createWindow();
  schedule();
  runScan();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

// Dev/verification hook: FPP_FINDER_DUMP=/path/out.json writes the first scan result and exits.
let dumped = false;
function onDone(r) {
  const out = process.env.FPP_FINDER_DUMP;
  if (out && !dumped) {
    dumped = true;
    try { fs.writeFileSync(out, JSON.stringify(r, null, 2)); } catch (e) { console.error(e); }
    if (process.env.FPP_FINDER_SHOT && win) {
      setTimeout(async () => { try { const img = await win.webContents.capturePage(); fs.writeFileSync(process.env.FPP_FINDER_SHOT, img.toPNG()); } catch (e) { console.error(e); } }, 1200);
    }
    if (process.env.FPP_FINDER_EXIT === '1') setTimeout(() => app.quit(), process.env.FPP_FINDER_SHOT ? 3000 : 300);
  }
}

app.on('window-all-closed', () => { if (scanner) scanner.stop(); app.quit(); });
module.exports = { sortDevices };
