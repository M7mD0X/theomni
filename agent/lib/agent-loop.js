// =====================================================================
// Omni-IDE Agent — Agent Loop (Streaming Thought → Tool → Observation)
// =====================================================================

const crypto = require('crypto');
const https = require('https');
const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const fsp = fs.promises;

const { buildSystemPrompt, invalidatePromptCache } = require('./system-prompt');
const { findFiles, grepFiles, detectProjectContext, projectTreeSample } = require('./fs-utils');
const { toolWorkspace, isUnder } = require('./security');
const { validateShellCommand } = require('./shell-validator');
const { LRUCache } = require('./lru-cache');

const MAX_ITER = 12;

// ── Response cache — proper LRU with TTL ───────────────────────────────
const _cache = new LRUCache({ maxSize: 64, ttlMs: 5 * 60 * 1000 });

function _cacheKey(system, messages, provider, model) {
  const h = crypto.createHash('sha256');
  h.update(system);
  for (const m of messages) h.update(m.role + '\u0000' + m.content + '\u0000');
  h.update(provider + '\u0000' + model);
  return h.digest('hex');
}

// ── Parse tool call from AI response ──────────────────────────────────
function parseTool(text) {
  if (!text) return null;
  const trimmed = text.trim();
  const fenceMatch = trimmed.match(/```(?:json)?\s*({[\s\S]*?})\s*```/);
  const candidate = fenceMatch ? fenceMatch[1] : trimmed;
  try {
    if (candidate.startsWith('{') && candidate.endsWith('}')) {
      const json = JSON.parse(candidate);
      if (json.tool && typeof json.tool === 'string' && json.params && typeof json.params === 'object') {
        return json;
      }
    }
  } catch {}
  const m = trimmed.match(/{\s*"tool"\s*:\s*"[^"]+"\s*,\s*"params"\s*:\s*\{[\s\S]*?\}\s*\}/);
  if (m) {
    try {
      const json = JSON.parse(m[0]);
      if (json.tool && json.params) return json;
    } catch {}
  }
  return null;
}

// ── Tool execution (all async) ────────────────────────────────────────
async function executeTool(ws, tool, params, agentConfig) {
  const WORKSPACE = toolWorkspace();
  const safe = (rel) => {
    const target = path.resolve(WORKSPACE, rel || '');
    if (!isUnder(target, WORKSPACE)) throw new Error('Path escapes workspace');
    return target;
  };

  switch (tool) {
    case 'list_files': {
      const dir = safe(params.path || '');
      if (!(await fs.promises.access(dir).then(() => true).catch(() => false)))
        return `Directory not found: ${params.path || '.'}`;
      const entries = await fsp.readdir(dir, { withFileTypes: true });
      const files = entries
        .map(e => e.isDirectory() ? `${e.name}/` : e.name)
        .sort();
      return files.length ? files.join('\n') : '(empty)';
    }

    case 'read_file': {
      const filePath = safe(params.path);
      let stat;
      try { stat = await fsp.stat(filePath); } catch { return `File not found: ${params.path}`; }
      if (stat.isDirectory()) return `Is a directory: ${params.path}`;
      const limit = Math.min(parseInt(params.max_bytes || '16384', 10), 64 * 1024);
      const buf = Buffer.alloc(limit);
      const fd = await fsp.open(filePath, 'r');
      const { bytesRead } = await fd.read(buf, 0, limit, 0);
      await fd.close();
      const out = buf.slice(0, bytesRead).toString('utf8');
      return stat.size > bytesRead ? out + `\n...(truncated, total ${stat.size} bytes)` : out;
    }

    case 'write_file': {
      const filePath = safe(params.path);
      const dir = path.dirname(filePath);
      await fsp.mkdir(dir, { recursive: true });
      await fsp.writeFile(filePath, params.content ?? '', 'utf8');
      // Invalidate system prompt cache since files changed
      invalidatePromptCache();
      return `Wrote ${Buffer.byteLength(params.content ?? '', 'utf8')} bytes -> ${params.path}`;
    }

    case 'patch_file': {
      const filePath = safe(params.path);
      let before;
      try { before = await fsp.readFile(filePath, 'utf8'); } catch { return `File not found: ${params.path}`; }
      const find = params.find ?? '';
      const replace = params.replace ?? '';
      if (!find) return `patch_file requires non-empty "find"`;
      if (!before.includes(find)) return `"find" string not found in ${params.path}`;
      const after = params.all
        ? before.split(find).join(replace)
        : before.replace(find, replace);
      await fsp.writeFile(filePath, after, 'utf8');
      invalidatePromptCache();
      const count = params.all ? (before.split(find).length - 1) : 1;
      return `Patched ${params.path} (${count} replacement${count === 1 ? '' : 's'})`;
    }

    case 'mkdir': {
      const dir = safe(params.path);
      await fsp.mkdir(dir, { recursive: true });
      invalidatePromptCache();
      return `Created ${params.path}`;
    }

    case 'delete_path': {
      const target = safe(params.path);
      try { await fsp.access(target); } catch { return `Not found: ${params.path}`; }
      if (path.resolve(target) === path.resolve(WORKSPACE)) return `Refusing to delete workspace root`;
      await fsp.rm(target, { recursive: true, force: true });
      invalidatePromptCache();
      return `Deleted ${params.path}`;
    }

    case 'find_files': {
      const root = safe(params.path || '');
      const pat = (params.pattern || '').toLowerCase();
      if (!pat) return `find_files requires "pattern"`;
      const hits = await findFiles(root, pat, WORKSPACE);
      return hits.length ? hits.join('\n') : '(no matches)';
    }

    case 'grep_in_files': {
      const root = safe(params.path || '');
      const q = params.query || '';
      if (!q) return `grep_in_files requires "query"`;
      const hits = await grepFiles(root, q, WORKSPACE);
      const formatted = hits.map(h => `${h.path}:${h.line}: ${h.preview}`);
      return formatted.length ? formatted.join('\n') : '(no matches)';
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
      const ctx = await detectProjectContext(WORKSPACE);
      const tree = await projectTreeSample(WORKSPACE);
      return JSON.stringify({
        workspace: WORKSPACE,
        stack: ctx.stack,
        notes: ctx.notes,
        tree_sample: tree.split('\n').slice(0, 40),
      }, null, 2);
    }

    default:
      return `Unknown tool: ${tool}`;
  }
}

// ── Live shell execution ───────────────────────────────────────────────
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

// ── AI provider call — streaming + retry + cache ──────────────────────
async function callAIWithRetry(ws, system, messages, agentConfig) {
  const key = _cacheKey(system, messages, agentConfig.provider, agentConfig.model);
  const cached = _cache.get(key);
  if (cached) {
    ws.send(JSON.stringify({ type: 'token', token: '' })); // wake the UI
    return cached;
  }

  let lastErr;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const reply = await callAIStream(ws, system, messages, agentConfig);
      _cache.set(key, reply);
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

function callAIStream(ws, system, messages, agentConfig) {
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

// ── Main agent loop ───────────────────────────────────────────────────
async function runAgentLoop(ws, userMessage, history, agentConfig) {
  const SYSTEM = await buildSystemPrompt();
  const messages = [...history, { role: 'user', content: userMessage }];

  ws.send(JSON.stringify({ type: 'thinking', message: 'Thinking...' }));

  for (let iter = 0; iter < MAX_ITER; iter++) {
    if (ws.__cancelled) {
      ws.send(JSON.stringify({ type: 'reply', message: '(cancelled)' }));
      return;
    }

    let reply;
    try {
      reply = await callAIWithRetry(ws, SYSTEM, messages, agentConfig);
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
      observation = await executeTool(ws, toolCall.tool, toolCall.params, agentConfig);
    } catch (err) {
      observation = `Error: ${err.message}`;
    }

    const obsPreview = String(observation).length > 600
      ? String(observation).slice(0, 600) + `\n...(+${String(observation).length - 600} chars)`
      : String(observation);

    ws.send(JSON.stringify({ type: 'tool_result', tool: toolCall.tool, result: obsPreview }));

    messages.push({ role: 'assistant', content: reply });
    messages.push({ role: 'user', content: `Tool result for ${toolCall.tool}:\n${observation}` });
  }

  ws.send(JSON.stringify({ type: 'reply', message: 'Reached max iteration limit. Try a more specific prompt.' }));
}

module.exports = { runAgentLoop, parseTool, executeTool, callAIWithRetry, callAIStream };
