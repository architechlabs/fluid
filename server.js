/**
 * Fluid Server — WebRTC Signaling + Device Management
 * Raspberry Pi Compute Module 4 | Production-Grade Screen Sharing
 */

'use strict';

const express    = require('express');
const http       = require('http');
const WebSocket  = require('ws');
const path       = require('path');
const { randomUUID } = require('crypto');
const fs         = require('fs');
const os         = require('os');
const { execFileSync } = require('child_process');

// ─── Configuration ──────────────────────────────────────────────────────────
loadEnvFile(path.join(__dirname, '.env'));

const PORT        = readIntEnv('PORT', 3000, 1, 65535);
const HOST        = process.env.HOST || '0.0.0.0';
const SERVER_PORT = readIntEnv('SERVER_PORT', PORT, 1, 65535);
const ADMIN_PIN   = String(process.env.ADMIN_PIN || '0000');
const LOG_FILE    = process.env.LOG_FILE || path.join(__dirname, 'logs', 'server.log');
const MAX_DEVICES = readIntEnv('MAX_DEVICES', 20, 1, 250);
const PUBLIC_DIR  = path.join(__dirname, 'public');
const INDEX_FILE  = path.join(PUBLIC_DIR, 'index.html');
const HTTPS_REDIRECT = readBoolEnv('HTTPS_REDIRECT', false);
const NATIVE_CAST_ENABLED = readBoolEnv('NATIVE_CAST_ENABLED', false);
const CAST_NAME = String(process.env.CAST_NAME || 'Fluid');
const NATIVE_CAST_MODE = String(process.env.NATIVE_CAST_MODE || 'all');
const MIRACAST_LINK = String(process.env.MIRACAST_LINK || 'auto');
const DISPLAY_LAYOUT_SCRIPT = path.join(__dirname, 'scripts', 'display-layout.sh');
const DISPLAY_LAYOUT_MODES = new Set(['auto', 'browser', 'native', 'split']);
const DEFAULT_ICE_SERVERS = [
  { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
];

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;

  const lines = fs.readFileSync(filePath, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;

    const [rawKey, ...rawValue] = trimmed.split('=');
    const key = rawKey.trim();
    if (process.env[key] !== undefined) continue;

    let value = rawValue.join('=').trim();
    value = value.replace(/^['"]|['"]$/g, '');
    process.env[key] = value;
  }
}

function readIntEnv(name, fallback, min, max) {
  const value = Number.parseInt(process.env[name] || String(fallback), 10);
  if (Number.isNaN(value) || value < min || value > max) {
    console.warn(`[CONFIG] Invalid ${name}; using ${fallback}`);
    return fallback;
  }
  return value;
}

function readBoolEnv(name, fallback) {
  const value = process.env[name];
  if (value === undefined) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

// ─── Logging ─────────────────────────────────────────────────────────────────
function timestamp() {
  return new Date().toISOString();
}

let logStream = null;
try {
  fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
  logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
} catch (_) {
  // If we can't write to /var/log, fall back to stdout only
}

function log(level, ...args) {
  const line = `[${timestamp()}] [${level}] ${args.join(' ')}`;
  console.log(line);
  if (logStream) logStream.write(line + '\n');
}

const logger = {
  info:  (...a) => log('INFO ', ...a),
  warn:  (...a) => log('WARN ', ...a),
  error: (...a) => log('ERROR', ...a),
};

// ─── App Setup ────────────────────────────────────────────────────────────────
const app    = express();
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server, path: '/ws' });

app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));
app.use((req, res, next) => {
  if (!HTTPS_REDIRECT || req.secure || req.headers['x-forwarded-proto'] === 'https') {
    return next();
  }

  const hostHeader = String(req.headers['x-forwarded-host'] || req.headers.host || '');
  const host = hostHeader.replace(/:\d+$/, '');
  const localHost = ['localhost', '127.0.0.1', '::1'].includes(host);
  if (!host || localHost || req.path.startsWith('/api/health')) return next();

  const privateIp = /^(10\.|127\.|172\.(1[6-9]|2\d|3[0-1])\.|192\.168\.)/.test(host);
  const localName = host.endsWith('.local') || !host.includes('.');
  const port = hostHeader.includes(':') || SERVER_PORT === 443 || (!privateIp && !localName)
    ? ''
    : `:${SERVER_PORT}`;
  return res.redirect(308, `https://${hostHeader.replace(/:\d+$/, '')}${port}${req.originalUrl}`);
});
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'same-origin');
  if (req.path === '/' || req.path.endsWith('.html')) {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
  }
  next();
});
app.use(express.static(PUBLIC_DIR, {
  extensions: ['html'],
  maxAge: process.env.NODE_ENV === 'production' ? '1h' : 0,
}));

// ─── State ────────────────────────────────────────────────────────────────────
// Map<deviceId, DeviceRecord>
const devices = new Map();
// Set<WebSocket> — admin/observer connections
const adminSockets = new Set();
// Map<displayId, WebSocket> — Pi HDMI display plus optional browser display viewers.
const displaySockets = new Map();

// Stats
const stats = {
  startedAt:       timestamp(),
  totalConnections: 0,
  totalSessions:   0,
};

// ─── Helpers ──────────────────────────────────────────────────────────────────
function safeSend(ws, data) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try { ws.send(JSON.stringify(data)); }
    catch (e) { logger.error('safeSend failed:', e.message); }
  }
}

function broadcastAdmins(data) {
  adminSockets.forEach(ws => safeSend(ws, data));
}

function broadcastDisplay(data) {
  displaySockets.forEach(ws => safeSend(ws, data));
}

function displayCount() {
  return displaySockets.size;
}

function displayOnline() {
  return displayCount() > 0;
}

function getDeviceList() {
  const list = [];
  devices.forEach((d, id) => {
    list.push({
      id,
      name:        d.name,
      platform:    d.platform || 'Unknown',
      status:      d.status,
      connectedAt: d.connectedAt,
      ip:          d.ip,
      isActive:    d.status === 'streaming',
    });
  });
  return list;
}

function getStreamingDeviceIds() {
  return [...devices.entries()]
    .filter(([, d]) => d.status === 'streaming')
    .map(([id]) => id);
}

function broadcastDeviceUpdate() {
  const activeDeviceIds = getStreamingDeviceIds();
  const payload = {
    type:           'device-list',
    devices:        getDeviceList(),
    activeDeviceId: activeDeviceIds[0] || null,
    activeDeviceIds,
  };
  broadcastAdmins(payload);
  broadcastDisplay(payload);
}

function serializeDevice(deviceId) {
  const dev = devices.get(deviceId);
  if (!dev) return null;
  return {
    id:          deviceId,
    name:        dev.name,
    platform:    dev.platform || 'Unknown',
    status:      dev.status,
    connectedAt: dev.connectedAt,
    ip:          dev.ip,
    isActive:    dev.status === 'streaming',
  };
}

function initiateDeviceDisplay(deviceId, reason) {
  if (!devices.has(deviceId)) return false;
  const dev = devices.get(deviceId);
  logger.info(`${reason} display start  id=${deviceId}  name="${dev.name}"`);
  displaySockets.forEach(display => {
    safeSend(display, {
      type: 'initiate-rtc',
      deviceId,
      device: serializeDevice(deviceId),
      displayId: display.displayId,
    });
  });
  return true;
}

function syncDisplayWall(reason) {
  const streamingIds = getStreamingDeviceIds();
  broadcastDeviceUpdate();
  if (!displayOnline() || streamingIds.length === 0) return;
  streamingIds.forEach(id => initiateDeviceDisplay(id, reason));
}

function getServerInfo() {
  const ifaces = os.networkInterfaces();
  const ips = [];
  Object.values(ifaces).forEach(arr => {
    arr.forEach(i => {
      if (i.family === 'IPv4' && !i.internal) ips.push(i.address);
    });
  });
  return {
    hostname:  os.hostname(),
    ips,
    platform:  os.platform(),
    uptime:    process.uptime(),
    stats,
    port:      PORT,
    publicPort: SERVER_PORT,
    rtcConfig: getRtcConfig(),
  };
}

function splitCsvEnv(value) {
  return String(value || '')
    .split(',')
    .map(item => item.trim())
    .filter(Boolean);
}

function getIceServers() {
  const rawJson = process.env.RTC_ICE_SERVERS_JSON;
  if (rawJson) {
    try {
      const parsed = JSON.parse(rawJson);
      if (Array.isArray(parsed) && parsed.length > 0) return parsed;
      logger.warn('RTC_ICE_SERVERS_JSON must be a non-empty JSON array; using fallback ICE config');
    } catch (error) {
      logger.warn('Invalid RTC_ICE_SERVERS_JSON:', error.message);
    }
  }

  const servers = readBoolEnv('RTC_INCLUDE_DEFAULT_STUN', true)
    ? [...DEFAULT_ICE_SERVERS]
    : [];
  const turnUrls = splitCsvEnv(process.env.RTC_TURN_URLS);
  if (turnUrls.length > 0) {
    const turnServer = { urls: turnUrls };
    if (process.env.RTC_TURN_USERNAME) turnServer.username = process.env.RTC_TURN_USERNAME;
    if (process.env.RTC_TURN_CREDENTIAL) turnServer.credential = process.env.RTC_TURN_CREDENTIAL;
    servers.push(turnServer);
  }
  return servers.length > 0 ? servers : DEFAULT_ICE_SERVERS;
}

function getRtcConfig() {
  const policy = String(process.env.RTC_ICE_TRANSPORT_POLICY || 'all').toLowerCase();
  return {
    iceServers: getIceServers(),
    iceTransportPolicy: ['all', 'relay'].includes(policy) ? policy : 'all',
  };
}

function commandExists(commandName) {
  try {
    if (process.platform === 'win32') execFileSync('where.exe', [commandName], { stdio: 'ignore' });
    else execFileSync('sh', ['-lc', `command -v ${commandName}`], { stdio: 'ignore' });
    return true;
  } catch (_) {
    return false;
  }
}

function serviceState(serviceName) {
  if (process.platform === 'win32' || !commandExists('systemctl')) return 'unavailable';
  try {
    return execFileSync('systemctl', ['is-active', serviceName], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || 'unknown';
  } catch (error) {
    return String(error.stdout || '').trim() || 'inactive';
  }
}

function runDisplayLayout(args) {
  if (process.platform === 'win32' || !fs.existsSync(DISPLAY_LAYOUT_SCRIPT)) {
    return { ok: false, error: 'Display layout manager is only available on the Raspberry Pi install.' };
  }
  try {
    const output = execFileSync('bash', [DISPLAY_LAYOUT_SCRIPT, ...args], {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { ok: true, output };
  } catch (error) {
    return {
      ok: false,
      error: String(error.stderr || error.message || 'Display layout command failed').trim(),
      output: String(error.stdout || '').trim(),
    };
  }
}

function parseDisplayLayoutStatus(output) {
  try {
    return JSON.parse(output);
  } catch (_) {
    return {
      configuredMode: 'unknown',
      effectiveMode: 'unknown',
      browserWindows: 0,
      nativeWindows: 0,
      browserWindow: '',
      nativeWindowIds: '',
      updatedAt: '',
    };
  }
}

function getDisplayLayoutStatus() {
  const result = runDisplayLayout(['status']);
  if (!result.ok && !result.output) {
    return {
      available: false,
      configuredMode: 'unavailable',
      effectiveMode: 'unavailable',
      browserWindows: 0,
      nativeWindows: 0,
      updatedAt: '',
      error: result.error,
    };
  }
  return { available: result.ok, ...parseDisplayLayoutStatus(result.output || '{}') };
}

function setDisplayLayoutMode(mode) {
  if (!DISPLAY_LAYOUT_MODES.has(mode)) {
    return { ok: false, error: 'Unsupported display layout mode' };
  }
  const result = runDisplayLayout(['set', mode]);
  if (!result.ok) return result;
  return { ok: true, status: { available: true, ...parseDisplayLayoutStatus(result.output || '{}') } };
}

function getCastStatus() {
  const airplayAvailable = commandExists('uxplay');
  const miracastAvailable = commandExists('miracle-sinkctl') && commandExists('miracle-wifid');
  const airplayService = serviceState('fluid-native-cast.service');
  const miracastService = serviceState('fluid-miracast.service');
  const miracastConfigured = MIRACAST_LINK !== 'auto';
  return {
    enabled: NATIVE_CAST_ENABLED,
    name: CAST_NAME,
    mode: NATIVE_CAST_MODE,
    services: {
      airplay: airplayService,
      miracast: miracastService,
    },
    wallIntegration: 'browser-wall-plus-native-hdmi-receivers',
    displayLayout: getDisplayLayoutStatus(),
    protocols: [
      {
        id: 'browser',
        label: 'Fluid Browser Share',
        status: 'ready',
        discoverable: false,
        wall: true,
        note: 'Stable multi-screen wall using the Fluid client page.',
      },
      {
        id: 'airplay',
        label: 'Apple AirPlay',
        status: !NATIVE_CAST_ENABLED ? 'disabled' : airplayAvailable ? airplayService : 'missing',
        discoverable: NATIVE_CAST_ENABLED && airplayAvailable && airplayService === 'active',
        wall: true,
        note: airplayAvailable
          ? 'Uses uxplay as the AirPlay receiver backend. The display layout manager can mix it beside the Fluid browser wall.'
          : 'Install uxplay on the Raspberry Pi to expose an AirPlay receiver.',
      },
      {
        id: 'miracast',
        label: 'Windows / Android Miracast',
        status: !NATIVE_CAST_ENABLED ? 'disabled' : miracastAvailable ? (miracastConfigured ? miracastService : 'needs-link') : 'not-installed',
        discoverable: NATIVE_CAST_ENABLED && miracastAvailable && miracastConfigured && miracastService === 'active',
        wall: miracastAvailable,
        note: miracastConfigured
          ? 'Uses MiracleCast as the Wi-Fi Direct sink. When available, the layout manager can mix it beside the Fluid browser wall.'
          : 'Set MIRACAST_LINK in /etc/fluid/fluid.env after running sudo miracle-sinkctl once to discover the link id.',
      },
      {
        id: 'google-cast',
        label: 'Google Cast / Chromecast',
        status: 'external',
        discoverable: false,
        wall: false,
        note: 'Google Cast receiver discovery is tied to the Cast receiver ecosystem and cannot be implemented as a normal LAN web app alone.',
      },
    ],
  };
}

function controlCastService(serviceId, action) {
  const services = {
    airplay: 'fluid-native-cast.service',
    miracast: 'fluid-miracast.service',
  };
  const actions = new Set(['start', 'stop', 'restart']);
  const serviceName = services[serviceId];
  if (!serviceName || !actions.has(action)) {
    return { ok: false, error: 'Unsupported cast service action' };
  }
  if (process.platform === 'win32' || !commandExists('systemctl')) {
    return { ok: false, error: 'systemctl is not available on this machine' };
  }
  try {
    if (typeof process.getuid === 'function' && process.getuid() !== 0 && commandExists('sudo')) {
      execFileSync('sudo', ['systemctl', action, serviceName], { stdio: 'ignore' });
    } else {
      execFileSync('systemctl', [action, serviceName], { stdio: 'ignore' });
    }
    return { ok: true, service: serviceName, action, state: serviceState(serviceName) };
  } catch (error) {
    return { ok: false, service: serviceName, action, error: error.message, state: serviceState(serviceName) };
  }
}

// ─── WebSocket Handler ────────────────────────────────────────────────────────
wss.on('connection', (ws, req) => {
  const clientId = randomUUID();
  ws.clientId = clientId;
  ws.role      = 'unknown';
  ws.isAlive   = true;
  stats.totalConnections++;

  // Extract IP from proxy headers or socket
  const ip =
    (req.headers['x-forwarded-for'] || '').split(',')[0].trim() ||
    req.socket.remoteAddress ||
    'unknown';
  ws.remoteIp = ip;

  logger.info(`WS connected  id=${clientId} ip=${ip}`);

  // Heartbeat pong
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw, isBinary) => {
    if (isBinary) {
      handleBinaryMessage(ws, raw);
      return;
    }
    let data;
    try { data = JSON.parse(raw); }
    catch { logger.warn(`Bad JSON from ${clientId}`); return; }
    handleMessage(ws, data);
  });

  ws.on('close', (code, reason) => {
    logger.info(`WS close  id=${clientId} role=${ws.role} code=${code}`);
    handleDisconnect(ws);
  });

  ws.on('error', err => {
    logger.error(`WS error  id=${clientId}:`, err.message);
  });

  // Send welcome
  safeSend(ws, { type: 'welcome', clientId, serverInfo: getServerInfo() });
});

// ─── Heartbeat Interval ───────────────────────────────────────────────────────
const heartbeatInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) {
      logger.warn(`Heartbeat timeout  id=${ws.clientId} role=${ws.role}`);
      ws.terminate();
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, 15000);

wss.on('close', () => clearInterval(heartbeatInterval));

const wallSyncInterval = setInterval(() => {
  if (displayOnline() && getStreamingDeviceIds().length > 0) {
    syncDisplayWall('Periodic sync');
  }
}, 5000);

wss.on('close', () => clearInterval(wallSyncInterval));

function splitRelayPacket(raw) {
  const packet = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  const maxHeader = Math.min(packet.length - 1, 8192);
  for (let i = 0; i < maxHeader; i++) {
    if (packet[i] === 10 && packet[i + 1] === 10) {
      const header = JSON.parse(packet.subarray(0, i).toString('utf8'));
      return { header, payload: packet.subarray(i + 2) };
    }
  }
  return null;
}

function makeRelayPacket(header, payload) {
  return Buffer.concat([
    Buffer.from(`${JSON.stringify(header)}\n\n`, 'utf8'),
    Buffer.isBuffer(payload) ? payload : Buffer.from(payload),
  ]);
}

function broadcastDisplayBinary(packet) {
  displaySockets.forEach(ws => {
    if (ws.readyState === WebSocket.OPEN) ws.send(packet, { binary: true });
  });
}

function handleBinaryMessage(ws, raw) {
  if (ws.role !== 'client' || !ws.deviceId) return;
  const dev = devices.get(ws.deviceId);
  if (!dev || dev.status !== 'streaming') return;

  let packet;
  try { packet = splitRelayPacket(raw); }
  catch (error) {
    logger.warn(`Bad binary relay packet from ${ws.deviceId}: ${error.message}`);
    return;
  }
  if (!packet || packet.header?.type !== 'relay-frame-binary' || packet.payload.length < 256) return;
  if (packet.payload.length > 512 * 1024) {
    logger.warn(`Relay frame too large from ${ws.deviceId}: ${packet.payload.length} bytes`);
    return;
  }

  broadcastDisplayBinary(makeRelayPacket({
    type: 'relay-frame-binary',
    deviceId: ws.deviceId,
    device: serializeDevice(ws.deviceId),
    frame: {
      width: Number(packet.header.frame?.width) || 0,
      height: Number(packet.header.frame?.height) || 0,
      sentAt: packet.header.frame?.sentAt || timestamp(),
      mime: packet.header.frame?.mime || 'image/jpeg',
      bytes: packet.payload.length,
    },
  }, packet.payload));
}

// ─── Message Router ───────────────────────────────────────────────────────────
function handleMessage(ws, data) {
  switch (data.type) {

    // ── Display registration (Pi Chromium kiosk) ──
    case 'register-display': {
      ws.role = 'display';
      ws.displayId = ws.clientId;
      displaySockets.set(ws.displayId, ws);
      logger.info(`Display registered  id=${ws.displayId}`);
      // Send current state
      safeSend(ws, {
        type:           'display-welcome',
        displayId:      ws.displayId,
        devices:        getDeviceList(),
        activeDeviceId: getStreamingDeviceIds()[0] || null,
        activeDeviceIds: getStreamingDeviceIds(),
        serverInfo:     getServerInfo(),
      });
      getStreamingDeviceIds().forEach(deviceId => {
        safeSend(ws, { type: 'initiate-rtc', deviceId, device: serializeDevice(deviceId), displayId: ws.displayId });
      });
      broadcastAdmins({ type: 'display-status', connected: true, count: displayCount() });
      break;
    }

    // ── Client registration (laptop/PC) ──
    case 'register-client': {
      if (devices.size >= MAX_DEVICES) {
        safeSend(ws, { type: 'error', message: 'Server full — max devices reached' });
        ws.close(1008, 'Server full');
        return;
      }
      const name = (data.name || '').trim().slice(0, 64) || `Device-${clientId.slice(0,6)}`;
      const deviceId = ws.clientId;
      devices.set(deviceId, {
        ws,
        name,
        platform:    data.platform || 'Unknown',
        status:      'connected',
        connectedAt: timestamp(),
        ip:          ws.remoteIp,
      });
      ws.role     = 'client';
      ws.deviceId = deviceId;
      stats.totalSessions++;
      logger.info(`Client registered  name="${name}"  id=${deviceId}`);
      safeSend(ws, { type: 'registered', deviceId, name });
      broadcastDeviceUpdate();
      break;
    }

    // ── Admin registration ──
    case 'register-admin': {
      if (data.pin !== ADMIN_PIN) {
        safeSend(ws, { type: 'auth-error', message: 'Invalid PIN' });
        logger.warn(`Bad admin PIN from ${ws.remoteIp}`);
        return;
      }
      ws.role = 'admin';
      adminSockets.add(ws);
      logger.info(`Admin connected  ip=${ws.remoteIp}`);
      safeSend(ws, {
        type:          'admin-welcome',
        devices:       getDeviceList(),
        activeDeviceId: getStreamingDeviceIds()[0] || null,
        activeDeviceIds: getStreamingDeviceIds(),
        serverInfo:    getServerInfo(),
        displayOnline: displayOnline(),
        displayCount:  displayCount(),
      });
      break;
    }

    // ── Admin: select device to display ──
    case 'select-device': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      const { deviceId } = data;
      if (deviceId === null || deviceId === undefined) {
      syncDisplayWall('Admin sync');
      logger.info('Admin synced display wall');
      return;
      }
      if (!devices.has(deviceId)) {
        safeSend(ws, { type: 'error', message: 'Device not found' });
        return;
      }
      initiateDeviceDisplay(deviceId, 'Admin');
      break;
    }

    case 'sync-display': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      syncDisplayWall('Admin sync');
      logger.info('Admin synced display wall');
      break;
    }

    // ── Admin: kick a device ──
    case 'kick-device': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      const dev = devices.get(data.deviceId);
      if (dev) {
        safeSend(dev.ws, { type: 'kicked', message: 'Removed by admin' });
        dev.ws.close(1000, 'Kicked by admin');
        logger.info(`Admin kicked device  id=${data.deviceId}`);
      }
      break;
    }

    // ── Admin: rename a device ──
    case 'rename-device': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      const dev = devices.get(data.deviceId);
      if (dev) {
        dev.name = (data.name || '').trim().slice(0, 64) || dev.name;
        logger.info(`Admin renamed device  id=${data.deviceId}  newName="${dev.name}"`);
        broadcastDeviceUpdate();
      }
      break;
    }

    // ── Admin: restart display ──
    case 'restart-display': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      broadcastDisplay({ type: 'reload' });
      logger.info('Admin triggered display reload');
      break;
    }

    // ── WebRTC signaling relay ──────────────────────────────────────────────
    // Display → Client
    case 'rtc-offer': {
      if (ws.role !== 'display') return;
      const target = devices.get(data.targetDeviceId);
      if (target) {
        safeSend(target.ws, {
          type: 'rtc-offer',
          offer: data.offer,
          displayId: ws.displayId,
        });
      }
      break;
    }

    // Client → Display
    case 'rtc-answer': {
      if (ws.role !== 'client') return;
      const display = displaySockets.get(data.displayId);
      safeSend(display, {
        type: 'rtc-answer',
        answer: data.answer,
        fromDeviceId: ws.deviceId,
        displayId: data.displayId,
      });
      break;
    }

    // Bidirectional ICE
    case 'rtc-ice': {
      if (ws.role === 'client') {
        const display = displaySockets.get(data.displayId);
        safeSend(display, {
          type: 'rtc-ice',
          candidate: data.candidate,
          fromDeviceId: ws.deviceId,
          displayId: data.displayId,
        });
      } else if (ws.role === 'display') {
        const target = devices.get(data.targetDeviceId);
        if (target) safeSend(target.ws, { type: 'rtc-ice', candidate: data.candidate, displayId: ws.displayId });
      }
      break;
    }

    // ── Client: stream started/stopped ──
    case 'stream-started': {
      if (ws.role !== 'client') return;
      const dev = devices.get(ws.deviceId);
      if (dev) dev.status = 'streaming';
      broadcastAdmins({ type: 'device-streaming', deviceId: ws.deviceId, streaming: true });
      logger.info(`Stream started  deviceId=${ws.deviceId}`);
      syncDisplayWall('Auto sync');
      break;
    }

    case 'stream-stopped': {
      if (ws.role !== 'client') return;
      const dev = devices.get(ws.deviceId);
      if (dev) dev.status = 'connected';
      broadcastAdmins({ type: 'device-streaming', deviceId: ws.deviceId, streaming: false });
      broadcastDisplay({ type: 'stream-ended', deviceId: ws.deviceId });
      logger.info(`Stream stopped  deviceId=${ws.deviceId}`);
      broadcastDeviceUpdate();
      break;
    }

    case 'relay-frame': {
      if (ws.role !== 'client' || !ws.deviceId || !data.frame?.dataUrl) return;
      const dev = devices.get(ws.deviceId);
      if (!dev || dev.status !== 'streaming') return;
      broadcastDisplay({
        type: 'relay-frame',
        deviceId: ws.deviceId,
        device: serializeDevice(ws.deviceId),
        frame: {
          dataUrl: String(data.frame.dataUrl),
          width: Number(data.frame.width) || 0,
          height: Number(data.frame.height) || 0,
          sentAt: data.frame.sentAt || timestamp(),
        },
      });
      break;
    }

    case 'relay-ended': {
      if (ws.role !== 'client' || !ws.deviceId) return;
      broadcastDisplay({ type: 'relay-ended', deviceId: ws.deviceId });
      break;
    }

    default:
      logger.warn(`Unknown message type "${data.type}" from ${ws.role}`);
  }
}

// ─── Disconnect Handler ───────────────────────────────────────────────────────
function handleDisconnect(ws) {
  switch (ws.role) {
    case 'display':
      if (ws.displayId) displaySockets.delete(ws.displayId);
      broadcastAdmins({ type: 'display-status', connected: displayOnline(), count: displayCount() });
      logger.info(`Display disconnected  id=${ws.displayId || 'unknown'}`);
      break;

    case 'client':
      if (ws.deviceId) {
        devices.delete(ws.deviceId);
        broadcastDisplay({ type: 'stream-ended', deviceId: ws.deviceId });
        broadcastDeviceUpdate();
        logger.info(`Client disconnected  id=${ws.deviceId}`);
      }
      break;

    case 'admin':
      adminSockets.delete(ws);
      logger.info(`Admin disconnected  ip=${ws.remoteIp}`);
      break;
  }
}

// ─── REST API ─────────────────────────────────────────────────────────────────
// Health check
app.get('/api/health', (req, res) => {
  res.json({
    status:        'ok',
    uptime:        process.uptime(),
    devices:       devices.size,
    activeDevice:  getStreamingDeviceIds()[0] || null,
    activeDevices: getStreamingDeviceIds(),
    displayOnline: displayOnline(),
    displayCount:  displayCount(),
    serverInfo:    getServerInfo(),
  });
});

// Simple PIN-protected device list endpoint (for integrations)
app.get('/api/devices', (req, res) => {
  if (req.query.pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json({ devices: getDeviceList(), activeDeviceId: getStreamingDeviceIds()[0] || null, activeDeviceIds: getStreamingDeviceIds() });
});

app.get('/api/cast/status', (req, res) => {
  if (req.query.pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json(getCastStatus());
});

app.post('/api/cast/:service/:action', (req, res) => {
  const pin = req.query.pin || req.body?.pin;
  if (pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  const result = controlCastService(req.params.service, req.params.action);
  if (!result.ok) return res.status(400).json(result);
  res.json({ ...result, status: getCastStatus() });
});

app.get('/api/display-layout/status', (req, res) => {
  if (req.query.pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json(getDisplayLayoutStatus());
});

app.post('/api/display-layout/:mode', (req, res) => {
  const pin = req.query.pin || req.body?.pin;
  if (pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  const result = setDisplayLayoutMode(req.params.mode);
  if (!result.ok) return res.status(400).json(result);
  res.json(result.status);
});

// Catch-all → serve index
app.get('*', (req, res) => {
  res.sendFile(INDEX_FILE);
});

// ─── Start ────────────────────────────────────────────────────────────────────
server.listen(PORT, HOST, () => {
  logger.info(`═══════════════════════════════════════`);
  logger.info(` Fluid Server  v1.0.0`);
  logger.info(` Listen   : ${HOST}:${PORT}`);
  logger.info(` Admin PIN: ${ADMIN_PIN === '0000' ? 'default PIN in use - change before real deployment' : 'configured'}`);
  logger.info(` Log file : ${LOG_FILE}`);
  logger.info(`═══════════════════════════════════════`);

  const ifaces = os.networkInterfaces();
  Object.values(ifaces).forEach(arr => {
    arr.forEach(i => {
      if (i.family === 'IPv4' && !i.internal) {
        logger.info(` Access   : http://${i.address}:${PORT}`);
      }
    });
  });
  logger.info(`═══════════════════════════════════════`);
});

// ─── Graceful Shutdown ────────────────────────────────────────────────────────
function shutdown(signal) {
  logger.info(`${signal} received — shutting down gracefully`);
  wss.clients.forEach(ws => ws.close(1001, 'Server shutting down'));
  server.close(() => {
    logger.info('Server closed');
    if (logStream) logStream.end();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('uncaughtException', err => {
  logger.error('Uncaught exception:', err.message, err.stack);
});
process.on('unhandledRejection', (reason) => {
  logger.error('Unhandled rejection:', reason);
});
