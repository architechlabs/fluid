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

  const host = String(req.headers.host || '').replace(/:\d+$/, '');
  const localHost = ['localhost', '127.0.0.1', '::1'].includes(host);
  if (!host || localHost || req.path.startsWith('/api/health')) return next();

  const port = SERVER_PORT === 443 ? '' : `:${SERVER_PORT}`;
  return res.redirect(308, `https://${host}${port}${req.originalUrl}`);
});
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'same-origin');
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
// The single Pi display WebSocket
let displayWs     = null;
let activeDeviceId = null;

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
  safeSend(displayWs, data);
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
      isActive:    id === activeDeviceId,
    });
  });
  return list;
}

function broadcastDeviceUpdate() {
  const payload = {
    type:           'device-list',
    devices:        getDeviceList(),
    activeDeviceId,
  };
  broadcastAdmins(payload);
  broadcastDisplay(payload);
}

function selectDeviceForDisplay(deviceId, reason) {
  if (!devices.has(deviceId)) return false;
  activeDeviceId = deviceId;
  const dev = devices.get(deviceId);
  logger.info(`${reason} selected device  id=${deviceId}  name="${dev.name}"`);
  broadcastDisplay({ type: 'initiate-rtc', deviceId });
  broadcastDeviceUpdate();
  return true;
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
  };
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

  ws.on('message', raw => {
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

// ─── Message Router ───────────────────────────────────────────────────────────
function handleMessage(ws, data) {
  switch (data.type) {

    // ── Display registration (Pi Chromium kiosk) ──
    case 'register-display': {
      if (displayWs && displayWs !== ws && displayWs.readyState === WebSocket.OPEN) {
        logger.warn('Second display attempted — terminating old one');
        displayWs.close(1000, 'Replaced by new display');
      }
      displayWs  = ws;
      ws.role    = 'display';
      logger.info('Display registered');
      // Send current state
      safeSend(ws, {
        type:           'display-welcome',
        devices:        getDeviceList(),
        activeDeviceId,
        serverInfo:     getServerInfo(),
      });
      broadcastAdmins({ type: 'display-status', connected: true });
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
        activeDeviceId,
        serverInfo:    getServerInfo(),
        displayOnline: displayWs?.readyState === WebSocket.OPEN,
      });
      break;
    }

    // ── Admin: select device to display ──
    case 'select-device': {
      if (ws.role !== 'admin') { safeSend(ws, { type: 'error', message: 'Unauthorized' }); return; }
      const { deviceId } = data;
      if (deviceId === null || deviceId === undefined) {
        // Deselect
        activeDeviceId = null;
        broadcastDisplay({ type: 'deselect' });
        broadcastDeviceUpdate();
        logger.info('Admin deselected device');
        return;
      }
      if (!devices.has(deviceId)) {
        safeSend(ws, { type: 'error', message: 'Device not found' });
        return;
      }
      selectDeviceForDisplay(deviceId, 'Admin');
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
      if (target) safeSend(target.ws, { type: 'rtc-offer', offer: data.offer });
      break;
    }

    // Client → Display
    case 'rtc-answer': {
      if (ws.role !== 'client') return;
      safeSend(displayWs, { type: 'rtc-answer', answer: data.answer, fromDeviceId: ws.deviceId });
      break;
    }

    // Bidirectional ICE
    case 'rtc-ice': {
      if (ws.role === 'client') {
        safeSend(displayWs, { type: 'rtc-ice', candidate: data.candidate, fromDeviceId: ws.deviceId });
      } else if (ws.role === 'display') {
        const target = devices.get(data.targetDeviceId || activeDeviceId);
        if (target) safeSend(target.ws, { type: 'rtc-ice', candidate: data.candidate });
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
      if (!activeDeviceId && displayWs?.readyState === WebSocket.OPEN) {
        selectDeviceForDisplay(ws.deviceId, 'Auto');
      } else {
        broadcastDeviceUpdate();
      }
      break;
    }

    case 'stream-stopped': {
      if (ws.role !== 'client') return;
      const dev = devices.get(ws.deviceId);
      if (dev) dev.status = 'connected';
      broadcastAdmins({ type: 'device-streaming', deviceId: ws.deviceId, streaming: false });
      broadcastDisplay({ type: 'stream-ended', deviceId: ws.deviceId });
      logger.info(`Stream stopped  deviceId=${ws.deviceId}`);
      if (activeDeviceId === ws.deviceId) {
        activeDeviceId = null;
        broadcastDisplay({ type: 'deselect' });
        broadcastDeviceUpdate();
      }
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
      displayWs = null;
      broadcastAdmins({ type: 'display-status', connected: false });
      logger.info('Display disconnected');
      break;

    case 'client':
      if (ws.deviceId) {
        devices.delete(ws.deviceId);
        if (activeDeviceId === ws.deviceId) {
          activeDeviceId = null;
          broadcastDisplay({ type: 'deselect' });
        }
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
    activeDevice:  activeDeviceId,
    displayOnline: displayWs?.readyState === WebSocket.OPEN,
    serverInfo:    getServerInfo(),
  });
});

// Simple PIN-protected device list endpoint (for integrations)
app.get('/api/devices', (req, res) => {
  if (req.query.pin !== ADMIN_PIN) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json({ devices: getDeviceList(), activeDeviceId });
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
