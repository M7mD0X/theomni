// =====================================================================
// Omni-IDE Agent — System Prompt Builder (with caching)
// =====================================================================

const path = require('path');
const fs = require('fs');
const fsp = fs.promises;
const { projectTreeSample, detectProjectContext } = require('./fs-utils');
const { toolWorkspace } = require('./security');

// Cache the system prompt for up to 30 seconds or until files change
let _cachedPrompt = null;
let _cachedAt = 0;
let _cachedMtime = 0;
const CACHE_TTL_MS = 30_000;

/**
 * Build (or return cached) project-aware system prompt.
 * Uses async file I/O. Caches result for 30s or until workspace mtime changes.
 */
async function buildSystemPrompt() {
  const WORKSPACE = toolWorkspace();

  // Quick check: if cache is fresh and workspace hasn't changed, reuse it
  const now = Date.now();
  if (_cachedPrompt && (now - _cachedAt) < CACHE_TTL_MS) {
    try {
      const stat = await fsp.stat(WORKSPACE);
      if (stat.mtimeMs === _cachedMtime) return _cachedPrompt;
    } catch {}
  }

  const [ctx, tree] = await Promise.all([
    detectProjectContext(WORKSPACE),
    projectTreeSample(WORKSPACE),
  ]);

  const stack = ctx.stack.length ? ctx.stack.join(', ') : 'unknown';

  _cachedPrompt = `You are Omni-IDE, a real, advanced AI coding agent running on Android.
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

  _cachedAt = now;
  try {
    const stat = await fsp.stat(WORKSPACE);
    _cachedMtime = stat.mtimeMs;
  } catch {}

  return _cachedPrompt;
}

/**
 * Force-invalidate the cache (e.g., after a file write/delete).
 */
function invalidatePromptCache() {
  _cachedPrompt = null;
  _cachedAt = 0;
}

module.exports = { buildSystemPrompt, invalidatePromptCache };
