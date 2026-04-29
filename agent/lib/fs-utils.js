// =====================================================================
// Omni-IDE Agent — Async Filesystem Utilities
// =====================================================================
// All I/O is async (fs.promises) to avoid blocking the Node.js event loop.

const fs = require('fs');
const path = require('path');
const fsp = fs.promises;

const SKIP_DIRS = new Set([
  'node_modules', '.git', '.dart_tool', 'build', '.gradle', '.idea',
  'dist', '.next', 'out', '__pycache__', '.cache', '.vscode',
]);

const MAX_SEARCH_RESULTS = 200;
const MAX_SEARCH_FILE_SIZE = 512 * 1024; // 512 KB

/**
 * Read directory entries asynchronously with stat info.
 * Returns { name, isDir, size, mtime }[].
 */
async function readDirStat(dirPath) {
  const names = await fsp.readdir(dirPath);
  // Parallel stat calls — much faster than sequential on large directories
  const results = await Promise.allSettled(
    names.map(async (name) => {
      const full = path.join(dirPath, name);
      try {
        const stat = await fsp.stat(full);
        return {
          name,
          isDir: stat.isDirectory(),
          size: stat.isDirectory() ? null : stat.size,
          mtime: stat.mtimeMs,
        };
      } catch {
        return { name, isDir: false, size: null, mtime: 0, broken: true };
      }
    })
  );
  return results
    .filter(r => r.status === 'fulfilled')
    .map(r => r.value);
}

/**
 * Async recursive file name search (glob/substring).
 * Returns relative paths from `rootDir`.
 */
async function findFiles(rootDir, pattern, workspace, { maxResults = 200 } = {}) {
  const pat = pattern.toLowerCase();
  if (!pat) return [];
  const hits = [];

  async function walk(dir) {
    if (hits.length >= maxResults) return;
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (hits.length >= maxResults) return;
      if (SKIP_DIRS.has(e.name)) continue;
      const full = path.join(dir, e.name);
      if (e.name.toLowerCase().includes(pat)) {
        hits.push(path.relative(workspace, full));
      }
      if (e.isDirectory()) await walk(full);
    }
  }

  await walk(rootDir);
  return hits;
}

/**
 * Async recursive content search (grep).
 * Returns { path, absPath, line, preview }[].
 */
async function grepFiles(rootDir, query, workspace, { maxResults = 100 } = {}) {
  let re;
  try { re = new RegExp(query, 'i'); }
  catch { re = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'); }

  const hits = [];

  async function walk(dir) {
    if (hits.length >= maxResults) return;
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (hits.length >= maxResults) return;
      if (e.name.startsWith('.') && e.name !== '.env') continue;
      if (SKIP_DIRS.has(e.name)) continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { await walk(full); continue; }
      let stat;
      try { stat = await fsp.stat(full); } catch { continue; }
      if (stat.size > MAX_SEARCH_FILE_SIZE) continue;
      let content;
      try { content = await fsp.readFile(full, 'utf8'); } catch { continue; }
      if (content.indexOf('\u0000') !== -1) continue;
      const lines = content.split('\n');
      for (let i = 0; i < lines.length && hits.length < maxResults; i++) {
        if (re.test(lines[i])) {
          hits.push({
            path: path.relative(workspace, full),
            absPath: full,
            line: i + 1,
            preview: lines[i].trim().slice(0, 180),
          });
        }
      }
    }
  }

  await walk(rootDir);
  return hits;
}

/**
 * Build a project tree sample (async). Used for system prompt context.
 * Returns newline-joined relative paths, max `maxEntries` items, depth ≤ 2.
 */
async function projectTreeSample(workspace, maxEntries = 60) {
  const out = [];
  async function walk(dir, depth) {
    if (out.length >= maxEntries) return;
    if (depth > 2) return;
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const e of entries) {
      if (out.length >= maxEntries) return;
      if (e.name.startsWith('.')) continue;
      if (SKIP_DIRS.has(e.name)) continue;
      const rel = path.relative(workspace, path.join(dir, e.name));
      out.push(rel + (e.isDirectory() ? '/' : ''));
      if (e.isDirectory()) await walk(path.join(dir, e.name), depth + 1);
    }
  }
  try { await walk(workspace, 0); } catch {}
  return out.join('\n');
}

/**
 * Detect project stack from marker files (async).
 */
async function detectProjectContext(workspace) {
  const ctx = { stack: [], notes: [] };
  const exists = async (p) => {
    try { await fsp.access(path.join(workspace, p)); return true; } catch { return false; }
  };
  if (await exists('pubspec.yaml')) ctx.stack.push('Flutter / Dart');
  if (await exists('package.json')) ctx.stack.push('Node.js');
  if (await exists('requirements.txt') || await exists('pyproject.toml')) ctx.stack.push('Python');
  if (await exists('Cargo.toml')) ctx.stack.push('Rust');
  if (await exists('go.mod')) ctx.stack.push('Go');
  if (await exists('android')) ctx.stack.push('Android (Kotlin / Gradle)');
  if (await exists('.git')) ctx.notes.push('git repository');
  return ctx;
}

/**
 * HTTP search endpoint handler (async, uses grepFiles).
 */
async function handleSearch(req, res, resolveSafe) {
  try {
    const root = resolveSafe(undefined, req.query.root);
    const q = (req.query.q || '').toString();
    if (!q) return res.json({ results: [] });
    if (!(await exists(root))) return res.json({ error: 'Root not found' });

    const results = await grepFiles(root, q, root);
    res.json({ results, truncated: results.length >= MAX_SEARCH_RESULTS });
  } catch (e) {
    res.status(e.code === 'EFORBIDDEN' ? 403 : 500).json({ error: e.message });
  }
}

async function exists(p) {
  try { await fsp.access(p); return true; } catch { return false; }
}

module.exports = {
  SKIP_DIRS,
  readDirStat,
  findFiles,
  grepFiles,
  projectTreeSample,
  detectProjectContext,
  handleSearch,
  exists,
  fsp,
};
