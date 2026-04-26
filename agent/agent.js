const WebSocket = require('ws');
const express = require('express');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const app = express();
app.use(express.json({ limit: '10mb' }));

const PORT = parseInt(process.env.OMNI_PORT || '8080', 10);

// HOME on Termux defaults to /data/data/com.termux/files/home, but we no longer
// depend on it being present — Cloud Mode users may run this agent on plain Linux,
// CI, or even desktop. We also expose the user's primary OmniIDE workspace
// (/storage/emulated/0/OmniIDE on Android) when it exists.
const HOME =
  process.env.HOME ||
  process.env.USERPROFILE ||
  process.env.OMNI_HOME ||
  '/data/data/com.termux/files/home';

const PROJECTS = process.env.OMNI_PROJECTS || path.join(HOME, 'omni-ide', 'projects');

// User-facing workspace (created by the Flutter app on first launch).
const OMNI_WORKSPACE =
  process.env.OMNI_WORKSPACE || '/storage/emulated/0/OmniIDE';

// Ensure baseline dirs exist (best-effort — no-op on systems where we can't write).
try {
  if (!fs.existsSync(PROJECTS)) fs.mkdirSync(PROJECTS, { recursive: true });
} catch {}

// ── Roots & safety ──────────────────────────────────────────────────────
// All filesystem operations must resolve to paths under one of these roots.
// We only advertise roots that actually exist on this machine, so the same
// agent code runs on Termux, plain Linux, and CI without exposing fake paths.
const _candidateRoots = [
  { id: 'omniide',  label: 'OmniIDE',  path: OMNI_WORKSPACE },
  { id: 'projects', label: 'Projects', path: PROJECTS },
  { id: 'sdcard',   label: 'Device',   path: '/storage/emulated/0' },
  { id: 'home',     label: 'HOME',     path: HOME },
  { id: 'termux',   label: 'Termux',   path: '/data/data/com.termux/files/home' },
  { id: 'legacy',   label: '/sdcard',  path: '/sdcard' },
];

const _seen = new Set();
const ROOTS = _candidateRoots.filter(r => {
  try {
    if (!r.path) return false;
    const resolved = path.resolve(r.path);
    if (_seen.has(resolved)) return false;
    if (!fs.existsSync(resolved)) return false;
    _seen.add(resolved);
    return true;
  } catch { return false; }
});

// Always have at least one root so the API never returns an empty list.
if (ROOTS.length === 0) ROOTS.push({ id: 'projects', label: 'Projects', path: PROJECTS });

function isUnder(child, parent) {
  const c = path.resolve(child);
  const p = path.resolve(parent);
  return c === p || c.startsWith(p + path.sep);
}

/** Resolve an incoming `path` query. Absolute paths must be under a known root.
 *  Relative paths resolve under the `root` query (default = projects). */
function resolveSafe(rawPath, rootId) {
  const root = ROOTS.find(r => r.id === rootId) || ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') {
    target = root.path;
  } else if (path.isAbsolute(rawPath)) {
    target = path.resolve(rawPath);
  } else {
    target = path.resolve(root.path, rawPath);
  }
  // Must stay inside one of the known roots
  const allowed = ROOTS.some(r => isUnder(target, r.path));
  if (!allowed) {
    const err = new Error(`Path is outside allowed roots: ${target}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }
  return target;
}

let agentConfig = {
  provider: 'openrouter',
  apiKey: '',
  model: 'anthropic/claude-3.5-sonnet',
};

// ── HTTP API ────────────────────────────────────────────────────────────

app.get('/ping', (_req, res) => {
  res.json({
    status: 'alive',
    agent: 'Omni-IDE',
    version: '2.0',
    model: agentConfig.model,
    roots: ROOTS.map(r => ({ id: r.id, label: r.label, path: r.path })),
  });
});

app.get('/roots', (_req, res) => {
  res.json({
    roots: ROOTS.map(r => ({
      id: r.id,
      label: r.label,
      path: r.path,
      exists: fs.existsSync(r.path),
    })),
  });
});

// List directory
app.get('/files', (req, res) => {
  try {
    const dir = resolveSafe(req.query.path, req.query.root);
    if (!fs.existsSync(dir)) return res.json({ error: 'Not found', path: dir });
    const stat = fs.statSync(dir);
    if (!stat.isDirectory()) return res.json({ error: 'Not a directory' });

    const items = fs.readdirSync(dir).map((name) => {
      const full = path.join(dir, name);
      try {
        const s = fs.statSync(full);
        return {
          name,
          isDir: s.isDirectory(),
          size: s.isDirectory() ? null : s.size,
          mtime: s.mtimeMs,
        };
      } catch {
        return { name, isDir: false, size: null, mtime: 0, broken: true };
      }
    });
    res.json({ items, absPath: dir });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Read file
app.get('/file', (req, res) => {
  try {
    const filePath = resolveSafe(req.query.path, req.query.root);
    if (!fs.existsSync(filePath)) return res.json({ error: 'Not found' });
    const stat = fs.statSync(filePath);
    if (stat.isDirectory()) return res.json({ error: 'Is a directory' });
    if (stat.size > 2 * 1024 * 1024) {
      return res.json({ error: 'File too large (>2MB)' });
    }
    const content = fs.readFileSync(filePath, 'utf8');
    res.json({ content, size: stat.size, absPath: filePath });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Write file (create or update)
app.post('/file', (req, res) => {
  try {
    const filePath = resolveSafe(req.body.path, req.body.root);
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(filePath, req.body.content ?? '', 'utf8');
    res.json({ ok: true, absPath: filePath });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Make directory
app.post('/mkdir', (req, res) => {
  try {
    const dir = resolveSafe(req.body.path, req.body.root);
    if (fs.existsSync(dir)) return res.json({ error: 'Already exists' });
    fs.mkdirSync(dir, { recursive: true });
    res.json({ ok: true, absPath: dir });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Delete file or folder (recursive)
app.post('/delete', (req, res) => {
  try {
    const target = resolveSafe(req.body.path, req.body.root);
    // Forbid deleting an actual root
    if (ROOTS.some(r => path.resolve(r.path) === target)) {
      return res.status(403).json({ error: 'Cannot delete a root' });
    }
    if (!fs.existsSync(target)) return res.json({ error: 'Not found' });
    fs.rmSync(target, { recursive: true, force: true });
    res.json({ ok: true });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Rename / move
app.post('/rename', (req, res) => {
  try {
    const from = resolveSafe(req.body.from, req.body.root);
    const to   = resolveSafe(req.body.to,   req.body.root);
    if (!fs.existsSync(from)) return res.json({ error: 'Source not found' });
    if (fs.existsSync(to))    return res.json({ error: 'Destination exists' });
    const dir = path.dirname(to);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.renameSync(from, to);
    res.json({ ok: true, absPath: to });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// Grep search — recursive substring match across files
app.get('/search', (req, res) => {
  try {
    const root = resolveSafe(req.query.path, req.query.root);
    const q    = (req.query.q || '').toString();
    if (!q) return res.json({ results: [] });
    if (!fs.existsSync(root)) return res.json({ error: 'Root not found' });

    const SKIP_DIRS = new Set([
      'node_modules', '.git', '.dart_tool', 'build', '.gradle', '.idea', 'dist',
    ]);
    const MAX_RESULTS = 200;
    const MAX_FILE_SIZE = 512 * 1024; // 512 KB
    const results = [];
    const qLower = q.toLowerCase();

    function walk(dir) {
      if (results.length >= MAX_RESULTS) return;
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
      catch { return; }
      for (const e of entries) {
        if (results.length >= MAX_RESULTS) return;
        if (e.name.startsWith('.') && e.name !== '.env') continue;
        if (SKIP_DIRS.has(e.name)) continue;
        const full = path.join(dir, e.name);
        if (e.isDirectory()) {
          walk(full);
        } else if (e.isFile()) {
          let stat; try { stat = fs.statSync(full); } catch { continue; }
          if (stat.size > MAX_FILE_SIZE) continue;
          let content;
          try { content = fs.readFileSync(full, 'utf8'); }
          catch { continue; }
          // Skip binary-ish (lots of NULs)
          if (content.indexOf('\u0000') !== -1) continue;
          const lines = content.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].toLowerCase().includes(qLower)) {
              results.push({
                path: path.relative(root, full),
                absPath: full,
                line: i + 1,
                preview: lines[i].trim().slice(0, 200),
              });
              if (results.length >= MAX_RESULTS) return;
            }
          }
        }
      }
    }

    walk(root);
    res.json({ results, truncated: results.length >= MAX_RESULTS });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

// ── Server ──────────────────────────────────────────────────────────────
const server = app.listen(PORT, () => {
  console.log(`[Agent] Running on port ${PORT}`);
  console.log(`[Agent] Roots:`);
  ROOTS.forEach(r => console.log(`  - ${r.id.padEnd(10)} ${r.path}`));
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  console.log('[Agent] Flutter connected');
  ws.send(JSON.stringify({ type: 'status', message: 'Agent Ready' }));

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

    if (msg.type === 'message') {
      if (!agentConfig.apiKey) {
        ws.send(JSON.stringify({ type: 'error', message: 'No API key. Open Settings.' }));
        return;
      }
      await runAgentLoop(ws, msg.content, msg.history || []);
    }
  });

  ws.on('close', () => console.log('[Agent] Disconnected'));
});

// ============================================
// AGENT LOOP — Thought → Tool → Observation
// ============================================
async function runAgentLoop(ws, userMessage, history) {
  const SYSTEM = `You are Omni-IDE, an AI coding assistant running on Android.
You have access to the following tools. To use a tool, respond with ONLY this JSON format:
{"tool":"tool_name","params":{...}}

Available tools:
- list_files: {"tool":"list_files","params":{"path":"relative/path"}}
- read_file: {"tool":"read_file","params":{"path":"filename.js"}}
- write_file: {"tool":"write_file","params":{"path":"filename.js","content":"file content here"}}
- run_shell: {"tool":"run_shell","params":{"cmd":"node --version"}}

Rules:
- Use tools when the user asks to create/read/edit files or run commands
- After getting tool results, give a helpful response
- Workspace path: ${_toolWorkspace()}
- For normal conversation, just reply normally without JSON`;

  const messages = [...history, { role: 'user', content: userMessage }];

  ws.send(JSON.stringify({ type: 'thinking', message: 'Thinking...' }));

  let iterations = 0;
  const MAX_ITER = 5;

  while (iterations < MAX_ITER) {
    iterations++;

    let reply;
    try {
      reply = await callAI(SYSTEM, messages);
    } catch (err) {
      ws.send(JSON.stringify({ type: 'error', message: `AI Error: ${err.message}` }));
      return;
    }

    const toolCall = parseTool(reply);

    if (!toolCall) {
      ws.send(JSON.stringify({ type: 'reply', message: reply }));
      return;
    }

    ws.send(JSON.stringify({
      type: 'tool_call',
      tool: toolCall.tool,
      params: toolCall.params,
    }));

    let observation;
    try {
      observation = executeTool(toolCall.tool, toolCall.params);
    } catch (err) {
      observation = `Error: ${err.message}`;
    }

    ws.send(JSON.stringify({
      type: 'tool_result',
      tool: toolCall.tool,
      result: observation,
    }));

    messages.push({ role: 'assistant', content: reply });
    messages.push({ role: 'user', content: `Tool result:\n${observation}` });
  }

  ws.send(JSON.stringify({ type: 'reply', message: 'Done.' }));
}

function parseTool(text) {
  try {
    const trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      const json = JSON.parse(trimmed);
      if (json.tool && json.params) return json;
    }
    return null;
  } catch {
    return null;
  }
}

function _toolWorkspace() {
  // Prefer the OmniIDE workspace, fall back to the first available root.
  const omni = ROOTS.find(r => r.id === 'omniide');
  if (omni) return omni.path;
  const proj = ROOTS.find(r => r.id === 'projects');
  if (proj) return proj.path;
  return ROOTS[0].path;
}

function executeTool(tool, params) {
  const WORKSPACE = _toolWorkspace();
  switch (tool) {
    case 'list_files': {
      const dir = path.join(WORKSPACE, params.path || '');
      if (!fs.existsSync(dir)) return `Directory not found: ${dir}`;
      const files = fs.readdirSync(dir);
      return files.length > 0 ? files.join('\n') : '(empty directory)';
    }
    case 'read_file': {
      const filePath = path.join(WORKSPACE, params.path);
      if (!fs.existsSync(filePath)) return `File not found: ${params.path}`;
      const content = fs.readFileSync(filePath, 'utf8');
      return content.length > 3000 ? content.substring(0, 3000) + '\n...(truncated)' : content;
    }
    case 'write_file': {
      const filePath = path.join(WORKSPACE, params.path);
      const dir = path.dirname(filePath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(filePath, params.content, 'utf8');
      return `File written: ${params.path}`;
    }
    case 'run_shell': {
      const forbidden = ['rm -rf /', 'mkfs', 'dd if=', 'shutdown', 'reboot'];
      for (const f of forbidden) {
        if (params.cmd.includes(f)) return `Command blocked for safety.`;
      }
      try {
        const output = execSync(params.cmd, {
          cwd: WORKSPACE,
          timeout: 15000,
          encoding: 'utf8',
          env: { ...process.env, PATH: process.env.PATH },
        });
        return output || '(no output)';
      } catch (err) {
        return `Exit ${err.status}: ${err.stderr || err.message}`;
      }
    }
    default:
      return `Unknown tool: ${tool}`;
  }
}

async function callAI(system, messages) {
  let url, headers, body;

  if (agentConfig.provider === 'anthropic') {
    url = 'https://api.anthropic.com/v1/messages';
    headers = {
      'x-api-key': agentConfig.apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    };
    body = JSON.stringify({
      model: agentConfig.model,
      max_tokens: 2048,
      system,
      messages,
    });
  } else {
    url = agentConfig.provider === 'openai'
      ? 'https://api.openai.com/v1/chat/completions'
      : 'https://openrouter.ai/api/v1/chat/completions';
    headers = {
      'Authorization': `Bearer ${agentConfig.apiKey}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://omni-ide.app',
      'X-Title': 'Omni-IDE',
    };
    body = JSON.stringify({
      model: agentConfig.model,
      max_tokens: 2048,
      messages: [{ role: 'system', content: system }, ...messages],
    });
  }

  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const req = https.request({
      hostname: urlObj.hostname,
      path: urlObj.pathname,
      method: 'POST',
      headers: { ...headers, 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', (c) => data += c);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (res.statusCode !== 200) {
            reject(new Error(json.error?.message || `Status ${res.statusCode}`));
            return;
          }
          const reply = agentConfig.provider === 'anthropic'
            ? json.content[0].text
            : json.choices[0].message.content;
          resolve(reply);
        } catch (e) {
          reject(new Error('Parse error'));
        }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
