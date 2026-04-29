// =====================================================================
// Omni-IDE Agent — Path Resolution & Security
// =====================================================================

const path = require('path');
const fs = require('fs');
const fsp = fs.promises;

let _ROOTS = [];

function initRoots() {
  const HOME =
    process.env.HOME ||
    process.env.USERPROFILE ||
    process.env.OMNI_HOME ||
    '/data/data/com.termux/files/home';

  const PROJECTS = process.env.OMNI_PROJECTS || path.join(HOME, 'omni-ide', 'projects');
  const OMNI_WORKSPACE = process.env.OMNI_WORKSPACE || '/storage/emulated/0/OmniIDE';

  try { if (!fs.existsSync(PROJECTS)) fs.mkdirSync(PROJECTS, { recursive: true }); } catch {}

  const _candidateRoots = [
    { id: 'omniide',  label: 'OmniIDE',  path: OMNI_WORKSPACE },
    { id: 'projects', label: 'Projects', path: PROJECTS },
    { id: 'sdcard',   label: 'Device',   path: '/storage/emulated/0' },
    { id: 'home',     label: 'HOME',     path: HOME },
    { id: 'termux',   label: 'Termux',   path: '/data/data/com.termux/files/home' },
    { id: 'legacy',   label: '/sdcard',  path: '/sdcard' },
  ];

  const _seen = new Set();
  _ROOTS = _candidateRoots.filter(r => {
    try {
      if (!r.path) return false;
      const resolved = path.resolve(r.path);
      if (_seen.has(resolved)) return false;
      if (!fs.existsSync(resolved)) return false;
      _seen.add(resolved);
      return true;
    } catch { return false; }
  });
  if (_ROOTS.length === 0) _ROOTS.push({ id: 'projects', label: 'Projects', path: PROJECTS });
  return _ROOTS;
}

function getRoots() { return _ROOTS; }

function isUnder(child, parent) {
  const c = path.resolve(child);
  const p = path.resolve(parent);
  return c === p || c.startsWith(p + path.sep);
}

/**
 * Async version of resolveSafe — uses fsp.realpath for symlink resolution.
 */
async function resolveSafeAsync(rawPath, rootId) {
  const root = _ROOTS.find(r => r.id === rootId) || _ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') target = root.path;
  else if (path.isAbsolute(rawPath)) target = path.resolve(rawPath);
  else target = path.resolve(root.path, rawPath);

  // Resolve symlinks to prevent path traversal via symlinks
  try {
    target = await fsp.realpath(target || root.path);
  } catch {
    // If realpath fails (broken symlink or doesn't exist yet),
    // use the non-resolved path for new-file creation scenarios.
    target = target || root.path;
  }

  const allowed = _ROOTS.some(r => isUnder(target, r.path));
  if (!allowed) {
    const err = new Error(`Path is outside allowed roots: ${target}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }
  return target;
}

/**
 * Sync version — kept for compatibility with existing HTTP routes during migration.
 */
function resolveSafe(rawPath, rootId) {
  const root = _ROOTS.find(r => r.id === rootId) || _ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') target = root.path;
  else if (path.isAbsolute(rawPath)) target = path.resolve(rawPath);
  else target = path.resolve(root.path, rawPath);
  try {
    target = fs.realpathSync(target || root.path);
  } catch {
    target = target || root.path;
  }
  const allowed = _ROOTS.some(r => isUnder(target, r.path));
  if (!allowed) {
    const err = new Error(`Path is outside allowed roots: ${target}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }
  return target;
}

function toolWorkspace() {
  const omni = _ROOTS.find(r => r.id === 'omniide');
  if (omni) return omni.path;
  const proj = _ROOTS.find(r => r.id === 'projects');
  if (proj) return proj.path;
  return _ROOTS[0].path;
}

module.exports = { initRoots, getRoots, isUnder, resolveSafe, resolveSafeAsync, toolWorkspace };
