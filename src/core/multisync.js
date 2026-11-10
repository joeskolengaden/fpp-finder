'use strict';
// Passive listener for FPP MultiSync discovery/ping packets on UDP 32320
// (FPP_CTRL_PORT, see fpp/src/MultiSync.h). We never send anything here.
const dgram = require('dgram');
const { EventEmitter } = require('events');

const FPP_CTRL_PORT = 32320;
const MULTICAST_GROUP = '239.70.80.80';
const CTRL_PKT_PING = 4;
const MODES = { 1: 'bridge', 2: 'player', 6: 'player', 8: 'remote' };

function cstr(buf, off, max) {
  if (off >= buf.length) return '';
  const end = Math.min(buf.length, off + max);
  let i = off;
  while (i < end && buf[i] !== 0) i++;
  return buf.toString('utf8', off, i);
}

// Layout from MultiSync::CreatePingPacket():
//  'FPPD' | type(1) | extraDataLen(u16 LE) | ed[0]=pingVersion, ed[1]=discover, ed[2]=systemType,
//  ed[3..4]=major BE, ed[5..6]=minor BE, ed[7]=mode, ed[8..11]=IPv4, ed[12..]=hostname(64),
//  ed[77..]=version(40), ed[118..]=model(40), ed[159..]=channel ranges(120)
function parsePingPacket(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 7 + 169) return null;
  if (buf.toString('ascii', 0, 4) !== 'FPPD') return null;
  if (buf[4] !== CTRL_PKT_PING) return null;
  const extraLen = buf.readUInt16LE(5);
  if (buf.length < 7 + Math.min(extraLen, 169)) return null;
  const ed = buf.subarray(7);
  const pingVersion = ed[0];
  if (pingVersion < 1 || pingVersion > 3) return null;
  const ip = `${ed[8]}.${ed[9]}.${ed[10]}.${ed[11]}`;
  return {
    pingVersion,
    discover: ed[1] === 1,
    systemType: ed[2],
    major: (ed[3] << 8) | ed[4],
    minor: (ed[5] << 8) | ed[6],
    mode: MODES[ed[7] & 0xfb] || null,
    sendingSync: (ed[7] & 0x04) !== 0,
    address: ip === '0.0.0.0' ? null : ip,
    hostname: cstr(ed, 12, 64),
    version: cstr(ed, 77, 40),
    model: cstr(ed, 118, 40),
  };
}

class MultiSyncListener extends EventEmitter {
  constructor({ log = () => {} } = {}) {
    super();
    this.log = log;
    this.sock = null;
    this.seen = new Map(); // ip -> {at, hostname, version, model, mode}
  }

  start(ifaces = []) {
    if (this.sock) return;
    try {
      const s = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      s.on('error', (e) => { this.log(`multisync: ${e.message}`); this.stop(); });
      s.on('message', (msg, rinfo) => {
        const p = parsePingPacket(msg);
        if (!p) return;
        const ip = p.address || rinfo.address;
        const rec = { at: Date.now(), hostname: p.hostname, version: p.version, model: p.model, mode: p.mode, from: rinfo.address };
        this.seen.set(ip, rec);
        this.emit('ping', ip, rec);
      });
      s.bind(FPP_CTRL_PORT, () => {
        for (const i of ifaces) { try { s.addMembership(MULTICAST_GROUP, i.ip); } catch (e) { /* not fatal */ } }
      });
      this.sock = s;
    } catch (e) { this.log(`multisync: ${e.message}`); }
  }

  stop() {
    if (this.sock) { try { this.sock.close(); } catch (e) { /* ignore */ } this.sock = null; }
  }
}

module.exports = { MultiSyncListener, parsePingPacket, FPP_CTRL_PORT };
