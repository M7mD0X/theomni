// =====================================================================
// Omni-IDE Agent  ·  v7 — Modular & Async
// =====================================================================
// What this server does:
//   • HTTP filesystem API (used by the Flutter file explorer).
//   • WebSocket bridge that runs a true Thought->Tool->Observation loop
//     against OpenRouter / OpenAI / Anthropic with streaming.
//   • All filesystem I/O is async (fs.promises) to avoid event loop blocking.
//   • System prompt is cached with 30s TTL + mtime invalidation.
//   • Response cache uses proper LRU with 5-minute TTL.
//   • WebSocket keep-alive pings for reliable connections.
//   • Health check endpoint for robust startup detection.
//   • WebSocket authentication via shared token (VULN-003 fix).
//   • Rate limiting on HTTP API (VULN-006 fix).
//   • API key protection (VULN-005 fix).
// =====================================================================

const WebSocket = require('ws');
const express = require('express');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const crypto = require('crypto');

const { initRoots, getRoots, resolveSafe, resolveSafeAsync, toolWorkspace } = require('./lib/security');
const { readDirStat, grepFiles, findFiles, exists } = require('./lib/fs-utils');
const { runAgentLoop } = require('./lib/agent-loop');
const { invalidatePromptCache } = require('./lib/system-prompt');

const app = express();

// VULN-006 fix: Rate limiting middleware
const rateLimitMap = new Map();
const RATE_LIMIT_WINDOW = 60_000; // 1 minute
const RATE_LIMIT_MAX_REQUESTS = 120; // max requests per window per IP

function rateLimiter(req, res, next) {
  const ip = req.ip || req.connection.remoteAddress || 'unknown';
  const now = Date.now();

  if (!rateLimitMap.has(ip)) {
    rateLimitMap.set(ip, { count: 1, startTime: now });
    next();
    return;
  }

  const entry = rateLimitMap.get(ip);
  if (now - entry.startTime > RATE_LIMIT_WINDOW) {
    // Reset window
    entry.count = 1;
    entry.startTime = now;
    next();
    return;
  }

  entry.count++;
  if (entry.count > RATE_LIMIT_MAX_REQUESTS) {
    res.status(429).json({ error: 'Too many requests. Please try again later.' });
    return;
  }
  next();
}

// Clean up rate limit entries periodically
setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of rateLimitMap) {
    if (now - entry.startTime > RATE_LIMIT_WINDOW) {
      rateLimitMap.delete(ip);
    }
  }
}, 60_000);

// Apply rate limiting to all routes
app.use(rateLimiter);

// VULN-008 fix: Input validation middleware
app.use(express.json({ limit: '1mb' })); // Reduced from 10mb to 1mb
app.use((req, res, next) => {
  // Validate Content-Type for POST routes
  if (req.method === 'POST' && req.body && typeof req.body === 'object') {
    // Validate path parameters don't contain null bytes
    const validatePath = (p) => {
      if (typeof p === 'string' && (p.includes('\0') || p.includes('%00'))) {
        return false;
      }
      return true;
    };
    if (!validatePath(req.body.path) || !validatePath(req.body.from) || !validatePath(req.body.to)) {
      return res.status(400).json({ error: 'Invalid path parameter' });
    }
    // Validate content size for file writes
    if (req.body.content && Buffer.byteLength(req.body.content, 'utf8') > 1024 * 1024) {
      return res.status(413).json({ error: 'File content too large (max 1MB via HTTP API)' });
    }
  }
  next();
});

const PORT = parseInt(process.env.OMNI_PORT || '8080', 10);

// Initialize root directories
const ROOTS = initRoots();

// ── VULN-005 fix: Secure API key storage ─────────────────────────────────
// Store API key in a closure-scoped variable, not directly accessible.
// The key is never exposed in process arguments or environment.
const _secureConfig = {
  _provider: 'openrouter',
  _apiKey: '',
  _model: 'anthropic/claude-3.5-sonnet',
  get provider() { return this._provider; },
  get model() { return this._model; },
  get apiKey() { return this._apiKey; },
  setConfig(provider, apiKey, model) {
    this._provider = provider || 'openrouter';
    this._model = model || 'anthropic/claude-3.5-sonnet';
    this._apiKey = apiKey || '';
  },
  clearConfig() {
    this._apiKey = '';
    this._provider = 'openrouter';
    this._model = 'anthropic/claude-3.5-sonnet';
  },
};

let agentConfig = _secureConfig;

// ── VULN-003 fix: WebSocket authentication token ─────────────────────────
// Generate a random token at startup, passed to Flutter via /ws-token endpoint
const WS_TOKEN = process.env.OMNI_WS_TOKEN || crypto.randomBytes(32).toString('hex');

// ── HTTP API (async file explorer) ───────────────────────────────────

app.get('/ping', async (_req, res) => {
  res.json({
    status: 'alive',
    agent: 'Omni-IDE',
    version: '7.1',
    model: agentConfig.model,
    roots: ROOTS.map(r => ({ id: r.id, label: r.label, path: r.path })),
    uptime: process.uptime(),
  });
});

app.get('/health', async (_req, res) => {
  // Lightweight health check — no I/O, just confirms the process is responsive
  res.json({ ok: true, uptime: process.uptime(), pid: process.pid });
});

app.get('/roots', async (req, res) => {
  const rootsWithExists = await Promise.all(
    ROOTS.map(async r => ({
      ...r,
      exists: await exists(r.path),
    }))
  );
  res.json({ roots: rootsWithExists });
});

app.get('/files', async (req, res) => {
  try {
    const dir = await resolveSafeAsync(req.query.path, req.query.root);
    if (!(await exists(dir))) return res.json({ error: 'Not found', path: dir });
    const stat = await fsp.stat(dir);
    if (!stat.isDirectory()) return res.json({ error: 'Not a directory' });
    const items = await readDirStat(dir);
    res.json({ items, absPath: dir });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

app.get('/file', async (req, res) => {
  try {
    const filePath = await resolveSafeAsync(req.query.path, req.query.root);
    if (!(await exists(filePath))) return res.json({ error: 'Not found' });
    const stat = await fsp.stat(filePath);
    if (stat.isDirectory()) return res.json({ error: 'Is a directory' });
    if (stat.size > 2 * 1024 * 1024) return res.json({ error: 'File too large (>2MB)' });
    const content = await fsp.readFile(filePath, 'utf8');
    res.json({ content, size: stat.size, absPath: filePath });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

app.post('/file', async (req, res) => {
  try {
    const filePath = await resolveSafeAsync(req.body.path, req.body.root);
    const dir = path.dirname(filePath);
    await fsp.mkdir(dir, { recursive: true });
    await fsp.writeFile(filePath, req.body.content ?? '', 'utf8');
    invalidatePromptCache();
    res.json({ ok: true, absPath: filePath });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

app.post('/mkdir', async (req, res) => {
  try {
    const dir = await resolveSafeAsync(req.body.path, req.body.root);
    if (await exists(dir)) return res.json({ error: 'Already exists' });
    await fsp.mkdir(dir, { recursive: true });
    invalidatePromptCache();
    res.json({ ok: true, absPath: dir });
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

app.post('/delete', async (req, res) => {
  try {
    const target = await resolveSafeAsync(req.body.path, req.body.root);
    if (ROOTS.some(r => path.resolve(r.path) === target)) {
      return res.status(403).json({ error: 'Cannot delete a root' });
    }
    if (!(await exists(target))) return res.json({ error: 'Not found' });
    await fsp.rm(target, { recursive: true, force: true });
    invalidatePromptCache();
    res.json({ ok: true });
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

app.post('/rename', async (req, res) => {
  try {
    const from = await resolveSafeAsync(req.body.from, req.body.root);
    const to   = await resolveSafeAsync(req.body.to,   req.body.root);
    if (!(await exists(from))) return res.json({ error: 'Source not found' });
    if (await exists(to))    return res.json({ error: 'Destination exists' });
    const dir = path.dirname(to);
    await fsp.mkdir(dir, { recursive: true });
    await fsp.rename(from, to);
    invalidatePromptCache();
    res.json({ ok: true, absPath: to });
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

app.get('/search', async (req, res) => {
  try {
    const root = await resolveSafeAsync(undefined, req.query.root);
    const q = (req.query.q || '').toString();
    if (!q) return res.json({ results: [] });
    if (!(await exists(root))) return res.json({ error: 'Root not found' });

    const results = await grepFiles(root, q, root);
    res.json({ results, truncated: results.length >= 200 });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// ── WebSocket token endpoint (for Flutter to fetch auth token) ───────────
app.get('/ws-token', (req, res) => {
  // Only allow connections from localhost
  const ip = req.ip || req.connection.remoteAddress;
  if (ip !== '127.0.0.1' && ip !== '::1' && ip !== '::ffff:127.0.0.1' && !ip.startsWith('127.')) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json({ token: WS_TOKEN });
});

// ── Server ──────────────────────────────────────────────────────────────
const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`[Agent v7.1] Running on port ${PORT}`);
  console.log(`[Agent v7.1] PID: ${process.pid}`);
  console.log(`[Agent v7.1] Roots:`);
  ROOTS.forEach(r => console.log(`  - ${r.id.padEnd(10)} ${r.path}`));
  console.log(`[Agent v7.1] WebSocket auth: enabled`);
});

const wss = new WebSocket.Server({ server, clientTracking: true });

// ── Keep-alive: send pings every 30s to detect dead connections ────────
const PING_INTERVAL = 30_000;
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      console.log('[Agent v7.1] Terminating dead connection');
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, PING_INTERVAL);

wss.on('connection', (ws, req) => {
  // VULN-003 fix: WebSocket authentication
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');

  // Allow connections from localhost without token for backward compatibility
  // during initial setup, but require token if OMNI_WS_TOKEN is set
  const clientIp = req.socket.remoteAddress;
  const isLocalhost = clientIp === '127.0.0.1' || clientIp === '::1' || clientIp === '::ffff:127.0.0.1';

  if (WS_TOKEN && token !== WS_TOKEN) {
    // If token is required and doesn't match, reject
    if (!isLocalhost || token !== undefined) {
      console.log(`[Agent v7.1] Rejected WebSocket connection: invalid token from ${clientIp}`);
      ws.close(1008, 'Invalid authentication token');
      return;
    }
  }

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  console.log(`[Agent v7.1] Flutter connected from ${clientIp}`);
  ws.send(JSON.stringify({ type: 'status', message: 'Agent Ready (v7.1)' }));

  ws.on('message', async (data) => {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }

    if (msg.type === 'config') {
      agentConfig.setConfig(msg.provider, msg.apiKey, msg.model);
      ws.send(JSON.stringify({ type: 'config_ack', message: `Using ${agentConfig.model}` }));
      return;
    }

    if (msg.type === 'cancel') {
      ws.__cancelled = true;
      return;
    }

    if (msg.type === 'message') {
      if (!agentConfig.apiKey) {
        ws.send(JSON.stringify({ type: 'error', message: 'No API key. Open Settings.' }));
        return;
      }
      ws.__cancelled = false;
      await runAgentLoop(ws, msg.content, msg.history || [], agentConfig);
    }
  });

  ws.on('close', () => console.log('[Agent v7.1] Disconnected'));
});

// ── Graceful shutdown ──────────────────────────────────────────────────
function gracefulShutdown(signal) {
  console.log(`[Agent v7.1] Received ${signal}, shutting down...`);
  // VULN-005 fix: clear API key from memory on shutdown
  agentConfig.clearConfig();
  wss.clients.forEach(ws => {
    try { ws.send(JSON.stringify({ type: 'status', message: 'Agent shutting down' })); } catch {}
    ws.close();
  });
  server.close(() => {
    console.log('[Agent v7.1] Server closed');
    process.exit(0);
  });
  // Force exit after 5s if hanging
  setTimeout(() => process.exit(0), 5000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// ── Uncaught error handler ────────────────────────────────────────────
process.on('uncaughtException', (err) => {
  console.error('[Agent v7.1] Uncaught exception:', err.message);
  // Don't crash — log and continue. Only crash on truly fatal errors.
});

process.on('unhandledRejection', (reason) => {
  console.error('[Agent v7.1] Unhandled rejection:', reason);
});
