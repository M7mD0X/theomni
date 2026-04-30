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

  // Block fork bombs — proper detection replacing broken backreference regex
  if (detectForkBomb(normalized)) {
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

  // Block Python/Perl/Ruby arbitrary code execution
  if (/\bpython[23]?\s+-c\b.*(?:os\.system|subprocess|exec|eval|__import__)/i.test(normalized)) {
    return { ok: false, reason: 'arbitrary code execution via Python is not allowed' };
  }
  if (/\bperl\s+-e\b/i.test(normalized)) {
    return { ok: false, reason: 'arbitrary code execution via Perl is not allowed' };
  }
  if (/\bruby\s+-e\b/i.test(normalized)) {
    return { ok: false, reason: 'arbitrary code execution via Ruby is not allowed' };
  }

  // Block `cd` followed by destructive commands (cd bypass for path checks)
  // e.g., `cd /; rm -rf *`
  const cdBypass = /(?:^|&&|;|\|)\s*cd\s+\S+\s*(?:&&|;|\|)\s*(?:rm|chmod|chown|mv|cp|dd|mkfs)\b/;
  if (cdBypass.test(normalized)) {
    return { ok: false, reason: 'cd followed by destructive command is not allowed' };
  }

  if (normalized.length > 4096) {
    return { ok: false, reason: 'command too long (max 4096 chars)' };
  }

  return { ok: true };
}

/**
 * Detect fork bomb patterns in shell commands.
 *
 * Catches:
 *   - Classic bash fork bomb: :(){ :|:& };:
 *   - Named function fork bombs: f(){ f|f& }; f
 *   - Recursive process spawning patterns
 *   - Self-referencing shell invocations
 */
function detectForkBomb(cmd) {
  // Classic bash fork bomb :(){ :|:& };:
  if (/:\s*\(\)\s*\{[^}]*:\s*\|.*&/i.test(cmd)) {
    return true;
  }

  // Named function fork bombs: function(){ ... | function & }
  // Matches: func(){ func|func& }; func
  const funcMatch = cmd.match(/\b(\w+)\s*\(\)\s*\{/);
  if (funcMatch) {
    const funcName = funcMatch[1];
    // Check if the function body references itself with pipe or background
    const funcBodyPattern = new RegExp(`\\b${escapeRegex(funcName)}\\b.*[|&]`);
    if (funcBodyPattern.test(cmd)) {
      return true;
    }
  }

  // Recursive shell spawning: sh -c "$(... $0 ...)" or bash $0
  if (/\b(?:sh|bash|dash|zsh)\b.*\$(?:0|BASH_SOURCE)/.test(cmd)) {
    return true;
  }

  // Process spawning loops: while true; do ... & done
  if (/while\s+true\s*;?\s*do\b/.test(cmd) && /&\s*$/.test(cmd.trim())) {
    return true;
  }

  return false;
}

/**
 * Escape special regex characters in a string.
 */
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

module.exports = { validateShellCommand, detectForkBomb };
