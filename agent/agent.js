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
// =====================================================================

const WebSocket = require('ws');
const express = require('express');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

const { initRoots, getRoots, resolveSafe, resolveSafeAsync, toolWorkspace } = require('./lib/security');
const { readDirStat, grepFiles, findFiles, exists } = require('./lib/fs-utils');
const { runAgentLoop } = require('./lib/agent-loop');
const { invalidatePromptCache } = require('./lib/system-prompt');

const app = express();
app.use(express.json({ limit: '10mb' }));

const PORT = parseInt(process.env.OMNI_PORT || '8080', 10);

// Initialize root directories
const ROOTS = initRoots();

// ── Agent config (per-connection in future, global for now) ─────────
let agentConfig = {
  provider: 'openrouter',
  apiKey: '',
  model: 'anthropic/claude-3.5-sonnet',
};

// ── HTTP API (async file explorer) ───────────────────────────────────

app.get('/ping', async (_req, res) => {
  res.json({
    status: 'alive',
    agent: 'Omni-IDE',
    version: '6.0',
    model: agentConfig.model,
    roots: ROOTS.map(r => ({ id: r.id, label: r.label, path: r.path })),
    uptime: process.uptime(),
  });
});

app.get('/health', async (_req, res) => {
  // Lightweight health check — no I/O, just confirms the process is responsive
  res.json({ ok: true, uptime: process.uptime(), pid: process.pid });
});

app.get('/roots', async (_req, res) => {
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

// ── Server ──────────────────────────────────────────────────────────────
const server = app.listen(PORT, () => {
  console.log(`[Agent v7] Running on port ${PORT}`);
  console.log(`[Agent v7] PID: ${process.pid}`);
  console.log(`[Agent v7] Roots:`);
  ROOTS.forEach(r => console.log(`  - ${r.id.padEnd(10)} ${r.path}`));
});

const wss = new WebSocket.Server({ server, clientTracking: true });

// ── Keep-alive: send pings every 30s to detect dead connections ────────
const PING_INTERVAL = 30_000;
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      console.log('[Agent v7] Terminating dead connection');
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, PING_INTERVAL);

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  console.log('[Agent v7] Flutter connected');
  ws.send(JSON.stringify({ type: 'status', message: 'Agent Ready (v7)' }));

  ws.on('message', async (data) => {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }

    if (msg.type === 'config') {
      agentConfig = {
        provider: msg.provider || 'openrouter',
        apiKey: msg.apiKey || '',
        model: msg.model || 'anthropic/claude-3.5-sonnet',
      };
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

  ws.on('close', () => console.log('[Agent v7] Disconnected'));
});

// ── Graceful shutdown ──────────────────────────────────────────────────
function gracefulShutdown(signal) {
  console.log(`[Agent v7] Received ${signal}, shutting down...`);
  wss.clients.forEach(ws => {
    try { ws.send(JSON.stringify({ type: 'status', message: 'Agent shutting down' })); } catch {}
    ws.close();
  });
  server.close(() => {
    console.log('[Agent v7] Server closed');
    process.exit(0);
  });
  // Force exit after 5s if hanging
  setTimeout(() => process.exit(0), 5000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// ── Uncaught error handler ────────────────────────────────────────────
process.on('uncaughtException', (err) => {
  console.error('[Agent v7] Uncaught exception:', err.message);
  // Don't crash — log and continue. Only crash on truly fatal errors.
});

process.on('unhandledRejection', (reason) => {
  console.error('[Agent v7] Unhandled rejection:', reason);
});
