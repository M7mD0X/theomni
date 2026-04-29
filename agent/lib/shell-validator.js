// =====================================================================
// Omni-IDE Agent — Shell Command Validation
// =====================================================================

function validateShellCommand(cmd, workspace) {
  if (!cmd || !cmd.trim()) return { ok: false, reason: 'empty command' };

  const normalized = cmd.trim();

  // Block explicit destructive patterns
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

  // Block pipe-to-shell and base64 decode tricks
  const pipeTricks = /\|\s*(?:sh|bash|dash|zsh|fish)\b/;
  if (pipeTricks.test(normalized)) {
    return { ok: false, reason: 'pipe to shell is not allowed' };
  }

  // Block eval with base64
  if (/\b(?:eval|exec)\b.*\bbase64\b/i.test(normalized)) {
    return { ok: false, reason: 'eval with base64 decode is not allowed' };
  }

  if (normalized.length > 4096) {
    return { ok: false, reason: 'command too long (max 4096 chars)' };
  }

  return { ok: true };
}

module.exports = { validateShellCommand };
