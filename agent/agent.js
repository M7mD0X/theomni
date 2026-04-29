// =====================================================================
// Omni-IDE Agent  ·  Phase 5 — Real Agent
// =====================================================================
// What this server does:
//   • HTTP filesystem API (used by the Flutter file explorer).
//   • WebSocket bridge that runs a true Thought→Tool→Observation loop
//     against OpenRouter / OpenAI / Anthropic with:
//        - streaming token-by-token reveal
//        - rich tool set: list_files, read_file, write_file, patch_file,
//          grep_in_files, find_files, run_shell (live stdout), git_*,
//          mkdir, delete_path, project_info
//        - retry with exponential backoff on transient HTTP failures
//        - tool-call response cache (in-memory, hash of messages)
//        - project-aware system prompt (auto-detected stack + tree sample)
// =====================================================================

const WebSocket = require('ws');
const express = require('express');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execSync, spawn } = require('child_process');

const app = express();
app.use(express.json({ limit: '10mb' }));

const PORT = parseInt(process.env.OMNI_PORT || '8080', 10);

const HOME =
  process.env.HOME ||
  process.env.USERPROFILE ||
  process.env.OMNI_HOME ||
  '/data/data/com.termux/files/home';

const PROJECTS = process.env.OMNI_PROJECTS || path.join(HOME, 'omni-ide', 'projects');
const OMNI_WORKSPACE = process.env.OMNI_WORKSPACE || '/storage/emulated/0/OmniIDE';

try { if (!fs.existsSync(PROJECTS)) fs.mkdirSync(PROJECTS, { recursive: true }); } catch {}

// ── Roots & safety ──────────────────────────────────────────────────────
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
if (ROOTS.length === 0) ROOTS.push({ id: 'projects', label: 'Projects', path: PROJECTS });

function isUnder(child, parent) {
  const c = path.resolve(child);
  const p = path.resolve(parent);
  return c === p || c.startsWith(p + path.sep);
}

function resolveSafe(rawPath, rootId) {
  const root = ROOTS.find(r => r.id === rootId) || ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') target = root.path;
  else if (path.isAbsolute(rawPath)) target = path.resolve(rawPath);
  else target = path.resolve(root.path, rawPath);
  // Resolve symlinks to prevent path traversal via symlinks
  try {
    target = fs.realpathSync(target || root.path);
  } catch {
    // If realpath fails (e.g., broken symlink or doesn't exist yet),
    // use the non-resolved path for new-file creation scenarios.
    target = target || root.path;
  }
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

// ── HTTP API (file explorer) ────────────────────────────────────────────

app.get('/ping', (_req, res) => {
  res.json({
    status: 'alive',
    agent: 'Omni-IDE',
    version: '5.0',
    model: agentConfig.model,
    roots: ROOTS.map(r => ({ id: r.id, label: r.label, path: r.path })),
  });
});

app.get('/roots', (_req, res) => {
  res.json({
    roots: ROOTS.map(r => ({ id: r.id, label: r.label, path: r.path, exists: fs.existsSync(r.path) })),
  });
});

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
        return { name, isDir: s.isDirectory(), size: s.isDirectory() ? null : s.size, mtime: s.mtimeMs };
      } catch { return { name, isDir: false, size: null, mtime: 0, broken: true }; }
    });
    res.json({ items, absPath: dir });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

app.get('/file', (req, res) => {
  try {
    const filePath = resolveSafe(req.query.path, req.query.root);
    if (!fs.existsSync(filePath)) return res.json({ error: 'Not found' });
    const stat = fs.statSync(filePath);
    if (stat.isDirectory()) return res.json({ error: 'Is a directory' });
    if (stat.size > 2 * 1024 * 1024) return res.json({ error: 'File too large (>2MB)' });
    const content = fs.readFileSync(filePath, 'utf8');
    res.json({ content, size: stat.size, absPath: filePath });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
});

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

app.post('/mkdir', (req, res) => {
  try {
    const dir = resolveSafe(req.body.path, req.body.root);
    if (fs.existsSync(dir)) return res.json({ error: 'Already exists' });
    fs.mkdirSync(dir, { recursive: true });
    res.json({ ok: true, absPath: dir });
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

app.post('/delete', (req, res) => {
  try {
    const target = resolveSafe(req.body.path, req.body.root);
    if (ROOTS.some(r => path.resolve(r.path) === target)) {
      return res.status(403).json({ error: 'Cannot delete a root' });
    }
    if (!fs.existsSync(target)) return res.json({ error: 'Not found' });
    fs.rmSync(target, { recursive: true, force: true });
    res.json({ ok: true });
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

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
  } catch (e) { res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message }); }
});

const SKIP_DIRS = new Set([
  'node_modules', '.git', '.dart_tool', 'build', '.gradle', '.idea', 'dist', '.next', 'out',
]);

app.get('/search', (req, res) => {
  try {
    const root = resolveSafe(undefined, req.query.root);
    const q    = (req.query.q || '').toString();
    if (!q) return res.json({ results: [] });
    if (!fs.existsSync(root)) return res.json({ error: 'Root not found' });
    const MAX_RESULTS = 200;
    const MAX_FILE_SIZE = 512 * 1024;
    const results = [];
    const qLower = q.toLowerCase();
    function walk(dir) {
      if (results.length >= MAX_RESULTS) return;
      let entries;
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (results.length >= MAX_RESULTS) return;
        if (e.name.startsWith('.') && e.name !== '.env') continue;
        if (SKIP_DIRS.has(e.name)) continue;
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full);
        else if (e.isFile()) {
          let stat; try { stat = fs.statSync(full); } catch { continue; }
          if (stat.size > MAX_FILE_SIZE) continue;
          let content; try { content = fs.readFileSync(full, 'utf8'); } catch { continue; }
          if (content.indexOf('\u0000') !== -1) continue;
          const lines = content.split('\n');
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].toLowerCase().includes(qLower)) {
              results.push({
                path: path.relative(root, full), absPath: full,
                line: i + 1, preview: lines[i].trim().slice(0, 200),
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
  console.log(`[Agent v5] Running on port ${PORT}`);
  console.log(`[Agent v5] Roots:`);
  ROOTS.forEach(r => console.log(`  - ${r.id.padEnd(10)} ${r.path}`));
});

const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  console.log('[Agent v5] Flutter connected');
  ws.send(JSON.stringify({ type: 'status', message: 'Agent Ready (v5)' }));

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
      await runAgentLoop(ws, msg.content, msg.history || []);
    }
  });

  ws.on('close', () => console.log('[Agent v5] Disconnected'));
});

// =====================================================================
// PROJECT-AWARE SYSTEM PROMPT
// =====================================================================
function _toolWorkspace() {
  const omni = ROOTS.find(r => r.id === 'omniide');
  if (omni) return omni.path;
  const proj = ROOTS.find(r => r.id === 'projects');
  if (proj) return proj.path;
  return ROOTS[0].path;
}

function detectProjectContext(workspace) {
  const ctx = { stack: [], notes: [] };
  const exists = (p) => { try { return fs.existsSync(path.join(workspace, p)); } catch { return false; } };
  if (exists('pubspec.yaml')) ctx.stack.push('Flutter / Dart');
  if (exists('package.json')) ctx.stack.push('Node.js');
  if (exists('requirements.txt') || exists('pyproject.toml')) ctx.stack.push('Python');
  if (exists('Cargo.toml')) ctx.stack.push('Rust');
  if (exists('go.mod')) ctx.stack.push('Go');
  if (exists('android')) ctx.stack.push('Android (Kotlin / Gradle)');
  if (exists('.git')) ctx.notes.push('git repository');
  return ctx;
}

function projectTreeSample(workspace, maxEntries = 60) {
  const out = [];
  function walk(dir, depth) {
    if (out.length >= maxEntries) return;
    if (depth > 2) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const e of entries) {
      if (out.length >= maxEntries) return;
      if (e.name.startsWith('.')) continue;
      if (SKIP_DIRS.has(e.name)) continue;
      const rel = path.relative(workspace, path.join(dir, e.name));
      out.push(rel + (e.isDirectory() ? '/' : ''));
      if (e.isDirectory()) walk(path.join(dir, e.name), depth + 1);
    }
  }
  try { walk(workspace, 0); } catch {}
  return out.join('\n');
}

function buildSystemPrompt() {
  const WORKSPACE = _toolWorkspace();
  const ctx = detectProjectContext(WORKSPACE);
  const tree = projectTreeSample(WORKSPACE);
  const stack = ctx.stack.length ? ctx.stack.join(', ') : 'unknown';
  return `You are Omni-IDE, a real, advanced AI coding agent running on Android.
You operate inside a developer's mobile IDE and have direct, unsandboxed
access to their workspace. You think step by step, take precise actions,
and explain results in plain language.

WORKSPACE: ${WORKSPACE}
DETECTED STACK: ${stack}
${ctx.notes.length ? 'NOTES: ' + ctx.notes.join(', ') + '\n' : ''}
PROJECT TREE (top 2 levels, sample):
${tree || '(empty)'}

# How you respond
Whenever you need to act on the filesystem, run a command, or inspect git,
respond with EXACTLY ONE JSON tool call on its own line — nothing else,
no prose, no markdown:

{"tool":"<name>","params":{...}}

You will then receive a tool result and may issue further tool calls.
When the task is complete OR no tool is needed, reply in plain prose
(NOT JSON) with a clear, concise answer for the user.

# Available tools
- list_files       params: {path?: string}                       — list directory entries
- read_file        params: {path: string, max_bytes?: number}    — read text file (truncates to 16k by default)
- write_file       params: {path: string, content: string}       — overwrite or create
- patch_file       params: {path: string, find: string, replace: string, all?: boolean} — exact-string edit
- mkdir            params: {path: string}                        — create directory
- delete_path      params: {path: string}                        — delete file or folder (recursive)
- find_files       params: {pattern: string, path?: string}      — name glob/substring search
- grep_in_files    params: {query: string, path?: string}        — recursive content search (regex)
- run_shell        params: {cmd: string}                         — runs in workspace, streams stdout live
- git_status       params: {}
- git_diff         params: {path?: string, staged?: boolean}
- git_log          params: {limit?: number}
- git_commit       params: {message: string, all?: boolean}
- project_info     params: {}                                    — re-detect stack & tree

# Rules
- Prefer reading before writing. Confirm a file's current state before editing.
- For edits, prefer patch_file over write_file when only a portion changes.
- Keep run_shell commands non-destructive unless the user asked.
- Never use rm -rf /, mkfs, dd, shutdown, reboot. They are blocked.
- After tool calls, summarise what you did in 1-3 sentences for the user.
- For pure conversation, just reply normally — DO NOT emit JSON.`;
}

// =====================================================================
// AGENT LOOP — Streaming Thought → Tool → Observation
// =====================================================================
const MAX_ITER = 12;
const _cache = new Map(); // simple LRU-ish

function _cacheKey(system, messages) {
  const h = crypto.createHash('sha256');
  h.update(system);
  for (const m of messages) h.update(m.role + '\u0000' + m.content + '\u0000');
  h.update(agentConfig.provider + '\u0000' + agentConfig.model);
  return h.digest('hex');
}

async function runAgentLoop(ws, userMessage, history) {
  const SYSTEM = buildSystemPrompt();
  const messages = [...history, { role: 'user', content: userMessage }];

  ws.send(JSON.stringify({ type: 'thinking', message: 'Thinking…' }));

  for (let iter = 0; iter < MAX_ITER; iter++) {
    if (ws.__cancelled) {
      ws.send(JSON.stringify({ type: 'reply', message: '(cancelled)' }));
      return;
    }

    let reply;
    try {
      reply = await callAIWithRetry(ws, SYSTEM, messages);
    } catch (err) {
      ws.send(JSON.stringify({ type: 'error', message: `AI Error: ${err.message}` }));
      return;
    }

    const toolCall = parseTool(reply);
    if (!toolCall) {
      ws.send(JSON.stringify({ type: 'reply', message: reply }));
      return;
    }

    ws.send(JSON.stringify({ type: 'tool_call', tool: toolCall.tool, params: toolCall.params }));

    let observation;
    try {
      observation = await executeTool(ws, toolCall.tool, toolCall.params);
    } catch (err) {
      observation = `Error: ${err.message}`;
    }

    const obsPreview = String(observation).length > 600
      ? String(observation).slice(0, 600) + `\n…(+${String(observation).length - 600} chars)`
      : String(observation);

    ws.send(JSON.stringify({ type: 'tool_result', tool: toolCall.tool, result: obsPreview }));

    messages.push({ role: 'assistant', content: reply });
    messages.push({ role: 'user', content: `Tool result for ${toolCall.tool}:\n${observation}` });
  }

  ws.send(JSON.stringify({ type: 'reply', message: 'Reached max iteration limit. Try a more specific prompt.' }));
}

function parseTool(text) {
  if (!text) return null;
  const trimmed = text.trim();
  // Allow ```json fences, leading/trailing prose noise, then look for first JSON obj.
  const fenceMatch = trimmed.match(/```(?:json)?\s*({[\s\S]*?})\s*```/);
  const candidate = fenceMatch ? fenceMatch[1] : trimmed;
  // Try the trimmed body first
  try {
    if (candidate.startsWith('{') && candidate.endsWith('}')) {
      const json = JSON.parse(candidate);
      if (json.tool && typeof json.tool === 'string' && json.params && typeof json.params === 'object') {
        return json;
      }
    }
  } catch {}
  // As a last resort, scan for the first {"tool": ...} block.
  const m = trimmed.match(/{\s*"tool"\s*:\s*"[^"]+"\s*,\s*"params"\s*:\s*\{[\s\S]*?\}\s*\}/);
  if (m) {
    try {
      const json = JSON.parse(m[0]);
      if (json.tool && json.params) return json;
    } catch {}
  }
  return null;
}

function validateShellCommand(cmd, workspace) {
  // Block empty commands
  if (!cmd || !cmd.trim()) return { ok: false, reason: 'empty command' };
  
  const normalized = cmd.trim();
  
  // Block explicit destructive patterns (normalized)
  const destructivePatterns = [
    /\brm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?\/\s*$/,
    /\brm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?\/\*.*$/,
    /\brm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)-/,
    /\bmkfs\b/,
    /\bdd\s+if=/,
    /\bshutdown\b/,
    /\breboot\b/,
    /\bpoweroff\b/,
    /\binit\s+0\b/,
    /\b:?\(\)\s*\{/,
    />\s*\/dev\/sd[a-z]/,
    /\bmv\s+\/\s/,
    /\bcp\s+.*\/dev\/zero/,
    /\bchmod\s+(-R\s+)?777\s+\//,
    /\bchown\s+(-R\s+)?/,
  ];
  
  for (const pattern of destructivePatterns) {
    if (pattern.test(normalized)) {
      return { ok: false, reason: 'destructive command pattern detected' };
    }
  }
  
  // Block path traversal attempts
  const pathTraversal = /(?:^|\s)(?:cd|rm|mv|cp|chmod|chown|mkdir|rmdir|ln|cat|write)\s+.*(?:\.\.\/){3,}/;
  if (pathTraversal.test(normalized)) {
    return { ok: false, reason: 'excessive path traversal detected' };
  }
  
  // Block commands targeting system directories
  const systemDirs = ['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/lib', '/boot', '/proc', '/sys', '/etc/shadow', '/etc/passwd'];
  for (const dir of systemDirs) {
    const pattern = new RegExp(`(?:^|\\s)(?:rm|mv|cp|chmod|chown|write|dd)\\s+.*${dir.replace('/', '\\/')}`, 'i');
    if (pattern.test(normalized)) {
      return { ok: false, reason: `system directory ${dir} is protected` };
    }
  }
  
  // Block fork bombs
  if (/\b(function|sh)\s*\(\)\s*\{/.test(normalized) && /\b\1\b/.test(normalized)) {
    return { ok: false, reason: 'recursive function (fork bomb pattern) detected' };
  }
  
  // Validate maximum command length
  if (normalized.length > 4096) {
    return { ok: false, reason: 'command too long (max 4096 chars)' };
  }
  
  return { ok: true };
}

// ── Tool runtime ────────────────────────────────────────────────────────
async function executeTool(ws, tool, params) {
  const WORKSPACE = _toolWorkspace();
  const safe = (rel) => {
    const target = path.resolve(WORKSPACE, rel || '');
    if (!isUnder(target, WORKSPACE)) throw new Error('Path escapes workspace');
    return target;
  };

  switch (tool) {
    case 'list_files': {
      const dir = safe(params.path || '');
      if (!fs.existsSync(dir)) return `Directory not found: ${params.path || '.'}`;
      const files = fs.readdirSync(dir, { withFileTypes: true })
        .map(e => e.isDirectory() ? `${e.name}/` : e.name).sort();
      return files.length ? files.join('\n') : '(empty)';
    }
    case 'read_file': {
      const filePath = safe(params.path);
      if (!fs.existsSync(filePath)) return `File not found: ${params.path}`;
      const stat = fs.statSync(filePath);
      if (stat.isDirectory()) return `Is a directory: ${params.path}`;
      const limit = Math.min(parseInt(params.max_bytes || '16384', 10), 64 * 1024);
      const buf = Buffer.alloc(limit);
      const fd = fs.openSync(filePath, 'r');
      const bytes = fs.readSync(fd, buf, 0, limit, 0);
      fs.closeSync(fd);
      const out = buf.slice(0, bytes).toString('utf8');
      return stat.size > bytes ? out + `\n…(truncated, total ${stat.size} bytes)` : out;
    }
    case 'write_file': {
      const filePath = safe(params.path);
      const dir = path.dirname(filePath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(filePath, params.content ?? '', 'utf8');
      return `Wrote ${Buffer.byteLength(params.content ?? '', 'utf8')} bytes → ${params.path}`;
    }
    case 'patch_file': {
      const filePath = safe(params.path);
      if (!fs.existsSync(filePath)) return `File not found: ${params.path}`;
      const before = fs.readFileSync(filePath, 'utf8');
      const find = params.find ?? '';
      const replace = params.replace ?? '';
      if (!find) return `patch_file requires non-empty "find"`;
      if (!before.includes(find)) return `"find" string not found in ${params.path}`;
      const after = params.all
        ? before.split(find).join(replace)
        : before.replace(find, replace);
      fs.writeFileSync(filePath, after, 'utf8');
      const count = params.all ? (before.split(find).length - 1) : 1;
      return `Patched ${params.path} (${count} replacement${count === 1 ? '' : 's'})`;
    }
    case 'mkdir': {
      const dir = safe(params.path);
      fs.mkdirSync(dir, { recursive: true });
      return `Created ${params.path}`;
    }
    case 'delete_path': {
      const target = safe(params.path);
      if (!fs.existsSync(target)) return `Not found: ${params.path}`;
      if (path.resolve(target) === path.resolve(WORKSPACE)) return `Refusing to delete workspace root`;
      fs.rmSync(target, { recursive: true, force: true });
      return `Deleted ${params.path}`;
    }
    case 'find_files': {
      const root = safe(params.path || '');
      const pat = (params.pattern || '').toLowerCase();
      if (!pat) return `find_files requires "pattern"`;
      const hits = [];
      (function walk(d) {
        if (hits.length >= 200) return;
        let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
        for (const e of ents) {
          if (hits.length >= 200) return;
          if (SKIP_DIRS.has(e.name)) continue;
          const full = path.join(d, e.name);
          if (e.name.toLowerCase().includes(pat)) hits.push(path.relative(WORKSPACE, full));
          if (e.isDirectory()) walk(full);
        }
      })(root);
      return hits.length ? hits.join('\n') : '(no matches)';
    }
    case 'grep_in_files': {
      const root = safe(params.path || '');
      const q = params.query || '';
      if (!q) return `grep_in_files requires "query"`;
      let re;
      try { re = new RegExp(q, 'i'); }
      catch { re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'); }
      const hits = [];
      (function walk(d) {
        if (hits.length >= 100) return;
        let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
        for (const e of ents) {
          if (hits.length >= 100) return;
          if (e.name.startsWith('.') && e.name !== '.env') continue;
          if (SKIP_DIRS.has(e.name)) continue;
          const full = path.join(d, e.name);
          if (e.isDirectory()) { walk(full); continue; }
          let stat; try { stat = fs.statSync(full); } catch { continue; }
          if (stat.size > 512 * 1024) continue;
          let content; try { content = fs.readFileSync(full, 'utf8'); } catch { continue; }
          if (content.indexOf('\u0000') !== -1) continue;
          const lines = content.split('\n');
          for (let i = 0; i < lines.length && hits.length < 100; i++) {
            if (re.test(lines[i])) {
              hits.push(`${path.relative(WORKSPACE, full)}:${i + 1}: ${lines[i].trim().slice(0, 180)}`);
            }
          }
        }
      })(root);
      return hits.length ? hits.join('\n') : '(no matches)';
    }
    case 'run_shell': {
      const safe = validateShellCommand(params.cmd, WORKSPACE);
      if (!safe.ok) return `Command blocked: ${safe.reason}`;
      return await runShellLive(ws, params.cmd, WORKSPACE);
    }
    case 'git_status': {
      try { return execSync('git status --short --branch', { cwd: WORKSPACE, encoding: 'utf8', timeout: 8000 }) || '(clean)'; }
      catch (e) { return `git_status error: ${e.stderr || e.message}`; }
    }
    case 'git_diff': {
      const args = params.staged ? '--cached' : '';
      const target = params.path ? `-- ${JSON.stringify(params.path)}` : '';
      try { return execSync(`git diff ${args} ${target}`, { cwd: WORKSPACE, encoding: 'utf8', timeout: 10000 }) || '(no diff)'; }
      catch (e) { return `git_diff error: ${e.stderr || e.message}`; }
    }
    case 'git_log': {
      const lim = Math.min(parseInt(params.limit || '10', 10), 50);
      try { return execSync(`git log --oneline -n ${lim}`, { cwd: WORKSPACE, encoding: 'utf8', timeout: 8000 }); }
      catch (e) { return `git_log error: ${e.stderr || e.message}`; }
    }
    case 'git_commit': {
      const msg = (params.message || '').replace(/"/g, '\\"');
      if (!msg) return `git_commit requires "message"`;
      const stage = params.all ? 'git add -A && ' : '';
      try { return execSync(`${stage}git commit -m "${msg}"`, { cwd: WORKSPACE, encoding: 'utf8', timeout: 15000 }); }
      catch (e) { return `git_commit error: ${e.stderr || e.message}`; }
    }
    case 'project_info': {
      const ctx = detectProjectContext(WORKSPACE);
      return JSON.stringify({
        workspace: WORKSPACE,
        stack: ctx.stack,
        notes: ctx.notes,
        tree_sample: projectTreeSample(WORKSPACE).split('\n').slice(0, 40),
      }, null, 2);
    }
    default:
      return `Unknown tool: ${tool}`;
  }
}

function runShellLive(ws, cmd, cwd) {
  return new Promise((resolve) => {
    const proc = spawn('sh', ['-c', cmd], { cwd, env: process.env });
    let out = '';
    let killed = false;
    const timer = setTimeout(() => {
      killed = true;
      try { proc.kill('SIGKILL'); } catch {}
    }, 30000);

    proc.stdout.on('data', (d) => {
      const s = d.toString('utf8');
      out += s;
      ws.send(JSON.stringify({ type: 'shell_chunk', chunk: s }));
      if (out.length > 64 * 1024) { try { proc.kill('SIGKILL'); } catch {} }
    });
    proc.stderr.on('data', (d) => {
      const s = d.toString('utf8');
      out += s;
      ws.send(JSON.stringify({ type: 'shell_chunk', chunk: s, stream: 'err' }));
    });
    proc.on('close', (code) => {
      clearTimeout(timer);
      const tail = killed ? '\n[killed: timeout or output limit]' : '';
      resolve(`(exit ${code})${tail}\n${out.slice(-4000)}`);
    });
    proc.on('error', (e) => {
      clearTimeout(timer);
      resolve(`spawn error: ${e.message}`);
    });
  });
}

// =====================================================================
// AI provider call — STREAMING + retry-with-backoff + cache
// =====================================================================
async function callAIWithRetry(ws, system, messages) {
  const key = _cacheKey(system, messages);
  if (_cache.has(key)) {
    const cached = _cache.get(key);
    ws.send(JSON.stringify({ type: 'token', token: '' })); // wake the UI
    return cached;
  }
  let lastErr;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const reply = await callAIStream(ws, system, messages);
      _cache.set(key, reply);
      if (_cache.size > 64) _cache.delete(_cache.keys().next().value);
      return reply;
    } catch (e) {
      lastErr = e;
      const msg = String(e.message || '');
      const transient = /5\d\d|ETIMEDOUT|ECONNRESET|EAI_AGAIN|rate.?limit|429/i.test(msg);
      if (!transient) throw e;
      const wait = 500 * Math.pow(2, attempt);
      await new Promise(r => setTimeout(r, wait));
    }
  }
  throw lastErr || new Error('AI call failed');
}

function callAIStream(ws, system, messages) {
  const cfg = agentConfig;
  let url, headers, body;

  if (cfg.provider === 'anthropic') {
    url = 'https://api.anthropic.com/v1/messages';
    headers = {
      'x-api-key': cfg.apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    };
    body = JSON.stringify({
      model: cfg.model, max_tokens: 2048, system, messages, stream: true,
    });
  } else {
    url = cfg.provider === 'openai'
      ? 'https://api.openai.com/v1/chat/completions'
      : 'https://openrouter.ai/api/v1/chat/completions';
    headers = {
      'Authorization': `Bearer ${cfg.apiKey}`,
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://omni-ide.app',
      'X-Title': 'Omni-IDE',
      'Accept': 'text/event-stream',
    };
    body = JSON.stringify({
      model: cfg.model, max_tokens: 2048,
      messages: [{ role: 'system', content: system }, ...messages],
      stream: true,
    });
  }

  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const req = https.request({
      hostname: urlObj.hostname,
      path: urlObj.pathname + urlObj.search,
      method: 'POST',
      headers: { ...headers, 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let buffer = '';
      let assembled = '';

      if (res.statusCode !== 200) {
        let err = '';
        res.on('data', c => err += c);
        res.on('end', () => {
          let parsed; try { parsed = JSON.parse(err); } catch {}
          reject(new Error((parsed && parsed.error && parsed.error.message) || `Status ${res.statusCode}: ${err.slice(0, 200)}`));
        });
        return;
      }

      res.on('data', (chunk) => {
        if (ws.__cancelled) { try { req.destroy(); } catch {} return; }
        buffer += chunk.toString('utf8');
        let idx;
        while ((idx = buffer.indexOf('\n\n')) >= 0) {
          const event = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 2);
          for (const line of event.split('\n')) {
            const trimmed = line.trim();
            if (!trimmed.startsWith('data:')) continue;
            const data = trimmed.slice(5).trim();
            if (!data || data === '[DONE]') continue;
            try {
              const evt = JSON.parse(data);
              let delta = '';
              if (cfg.provider === 'anthropic') {
                if (evt.type === 'content_block_delta' && evt.delta && evt.delta.text) {
                  delta = evt.delta.text;
                }
              } else {
                if (evt.choices && evt.choices[0] && evt.choices[0].delta && evt.choices[0].delta.content) {
                  delta = evt.choices[0].delta.content;
                }
              }
              if (delta) {
                assembled += delta;
                ws.send(JSON.stringify({ type: 'token', token: delta }));
              }
            } catch {}
          }
        }
      });
      res.on('end', () => resolve(assembled || '(empty response)'));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
