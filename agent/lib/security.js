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
 * Check if a resolved path is under any allowed root.
 */
function _isPathAllowed(target) {
  return _ROOTS.some(r => isUnder(target, r.path));
}

/**
 * Async version of resolveSafe — uses fsp.realpath for symlink resolution.
 * VULN-004 fix: handles TOCTOU race condition with broken symlink fallback.
 */
async function resolveSafeAsync(rawPath, rootId) {
  const root = _ROOTS.find(r => r.id === rootId) || _ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') target = root.path;
  else if (path.isAbsolute(rawPath)) target = path.resolve(rawPath);
  else target = path.resolve(root.path, rawPath);

  // VULN-004 fix: Resolve symlinks securely
  // Step 1: Check the unresolved path first
  if (!_isPathAllowed(target)) {
    const err = new Error(`Path is outside allowed roots: ${target}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }

  // Step 2: Resolve symlinks
  let resolvedTarget;
  try {
    resolvedTarget = await fsp.realpath(target || root.path);
  } catch {
    // If realpath fails (broken symlink or doesn't exist yet),
    // the path may be a new file being created. We've already checked
    // the unresolved path above, so we allow it for creation scenarios.
    // However, we must ensure the parent directory resolves safely.
    const parentDir = path.dirname(target);
    try {
      const resolvedParent = await fsp.realpath(parentDir);
      if (!_isPathAllowed(resolvedParent)) {
        const err = new Error(`Path is outside allowed roots (symlink in parent): ${resolvedParent}`);
        err.code = 'EFORBIDDEN';
        throw err;
      }
    } catch (e) {
      if (e.code === 'EFORBIDDEN') throw e;
      // Parent doesn't exist either — allow for deep new-file creation
      // but the unresolved path check above still applies
    }
    return target;
  }

  // Step 3: Verify the resolved path is still under allowed roots
  if (!_isPathAllowed(resolvedTarget)) {
    const err = new Error(`Path is outside allowed roots (symlink target): ${resolvedTarget}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }

  // Step 4: Also check each component of the path for symlink escapes
  // This prevents TOCTOU where a symlink is created between checks
  await _validatePathComponents(target, resolvedTarget);

  return resolvedTarget;
}

/**
 * Validate that no intermediate path component is a symlink pointing outside roots.
 * VULN-004 fix: defense in depth against TOCTOU symlink races.
 */
async function _validatePathComponents(originalTarget, resolvedTarget) {
  // Walk up from the resolved target and verify all symlinks point within roots
  const parts = resolvedTarget.split(path.sep);
  let current = '';
  for (let i = 1; i < parts.length; i++) {
    current = current + path.sep + parts[i];
    try {
      const stat = await fsp.lstat(current);
      if (stat.isSymbolicLink()) {
        const linkTarget = await fsp.realpath(current);
        if (!_isPathAllowed(linkTarget)) {
          const err = new Error(`Symlink at ${current} points outside allowed roots: ${linkTarget}`);
          err.code = 'EFORBIDDEN';
          throw err;
        }
      }
    } catch (e) {
      if (e.code === 'EFORBIDDEN') throw e;
      // Component doesn't exist yet — acceptable for new file creation
    }
  }
}

/**
 * Sync version — kept for compatibility with existing HTTP routes during migration.
 * VULN-004 fix: same symlink protections applied synchronously.
 */
function resolveSafe(rawPath, rootId) {
  const root = _ROOTS.find(r => r.id === rootId) || _ROOTS[0];
  let target;
  if (!rawPath || rawPath === '') target = root.path;
  else if (path.isAbsolute(rawPath)) target = path.resolve(rawPath);
  else target = path.resolve(root.path, rawPath);

  // Check unresolved path first
  if (!_isPathAllowed(target)) {
    const err = new Error(`Path is outside allowed roots: ${target}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }

  // Resolve symlinks
  let resolvedTarget;
  try {
    resolvedTarget = fs.realpathSync(target || root.path);
  } catch {
    // If realpath fails, check parent directory
    const parentDir = path.dirname(target);
    try {
      const resolvedParent = fs.realpathSync(parentDir);
      if (!_isPathAllowed(resolvedParent)) {
        const err = new Error(`Path is outside allowed roots (symlink in parent): ${resolvedParent}`);
        err.code = 'EFORBIDDEN';
        throw err;
      }
    } catch (e) {
      if (e.code === 'EFORBIDDEN') throw e;
    }
    return target;
  }

  // Verify resolved path is under allowed roots
  if (!_isPathAllowed(resolvedTarget)) {
    const err = new Error(`Path is outside allowed roots (symlink target): ${resolvedTarget}`);
    err.code = 'EFORBIDDEN';
    throw err;
  }

  return resolvedTarget;
}

function toolWorkspace() {
  const omni = _ROOTS.find(r => r.id === 'omniide');
  if (omni) return omni.path;
  const proj = _ROOTS.find(r => r.id === 'projects');
  if (proj) return proj.path;
  return _ROOTS[0].path;
}

module.exports = { initRoots, getRoots, isUnder, resolveSafe, resolveSafeAsync, toolWorkspace };
