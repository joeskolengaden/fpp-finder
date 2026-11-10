'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const on = (ch, cb) => { const f = (_e, p) => cb(p); ipcRenderer.on(ch, f); return () => ipcRenderer.removeListener(ch, f); };
contextBridge.exposeInMainWorld('finder', {
  platform: process.platform,
  getState: () => ipcRenderer.invoke('state:get'),
  scan: () => ipcRenderer.invoke('scan:run'),
  setSettings: (p) => ipcRenderer.invoke('settings:set', p),
  openWeb: (ip) => ipcRenderer.invoke('open:web', ip),
  copy: (t) => ipcRenderer.invoke('copy:text', t),
  onStart: (cb) => on('scan:start', cb),
  onProgress: (cb) => on('scan:progress', cb),
  onDone: (cb) => on('scan:done', cb),
  onError: (cb) => on('scan:error', cb),
});
