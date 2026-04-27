# Omni-IDE Progress Log

## Phase 1: Foundation [✅ Complete]
- [x] CI/CD pipeline (`.github/workflows/build.yml`) using `flutter create temp_app` strategy
- [x] Kotlin Guardian foreground service (START_STICKY)
- [x] Termux setup script (`scripts/setup_termux.sh`)
- [x] Flutter ↔ Guardian MethodChannel wiring

## Phase 2: Basic IDE shell [✅ Complete]
- [x] WebSocket handshake Flutter ↔ Node agent
- [x] Live agent status in UI
- [x] Port 8080 (HTTP + WS on same server)

## Phase 3: AI Brain [✅ Complete]
- [x] Provider picker (OpenRouter / Anthropic / OpenAI / Custom)
- [x] API key persistence via SharedPreferences
- [x] Live OpenRouter model list
- [x] Connection test
- [x] Node.js agent.js with Thought→Tool→Observation loop
- [x] Tools: list_files / read_file / write_file / run_shell
- [x] Real file explorer (HTTP REST) and editor tabs

## Phase 4 — UI/UX Full Overhaul [✅ Complete but Still need improvements]
- [x] New "Editorial Terminal" design system
  - Warm near-black canvas (#0B0A08), cream typography (#F2ECDE)
  - Single marigold accent (#FFB347), no rainbow gradients
  - Typography trio: Fraunces (display/italic), Inter Tight (UI), JetBrains Mono (code)
  - Design tokens: spacing (s_1–s_7), radii (sm/md/lg/xl/pill), motion (fast/med/slow), eOut/eInOut
  - New file-type color palette — muted and sophisticated
- [x] `google_fonts` integration (network-cached, no bundled assets)
- [x] TopBar — editorial wordmark, filename breadcrumb, animated Guardian pulse pill
- [x] Sidebar — activity rail (Files/Search/Agent tabs), breadcrumb header, hover/selection states, error recovery with retry, animated loading dots
- [x] Editor — refined tabs (underline indicator), clean gutter, `WelcomeView` with dot-grid background and editorial hero
- [x] Agent Panel — accent-striped agent messages, slate tool-call chips, sage-left-rule tool results, coral error blocks, suggestion chips, arrow-up send button with glow
- [x] Terminal Panel — brand line in Fraunces italic, clean prompt with marigold caret
- [x] Settings — bottom-sheet model picker with filter, card provider tiles, live test feedback (sage/coral), ghost/solid button pair
- [x] MainIDEScreen — draggable vertical split handle between editor and bottom panel, staggered entrance animation
- [x] All interactions: hover, pressed, focused states with T.dFast (140ms) transitions on specific properties

## Next Phases
### Phase 5 — Real Agent [✅ Complete]
- [x] Streaming token-by-token reveal (SSE) for OpenRouter / OpenAI / Anthropic
- [x] Rich tool registry: `list_files`, `read_file`, `write_file`, `patch_file`,
      `mkdir`, `delete_path`, `find_files`, `grep_in_files`, `run_shell` (live stdout),
      `git_status`, `git_diff`, `git_log`, `git_commit`, `project_info`
- [x] `run_shell` streams live stdout/stderr back to the UI as `shell_chunk` events
      (with 30 s timeout + 64 KB cap)
- [x] Project-aware system prompt — auto-detects stack (Flutter/Node/Python/Rust/Go/Android)
      and injects a 2-level workspace tree sample
- [x] Retry with exponential backoff on transient HTTP failures (5xx / 429 / ECONNRESET)
- [x] In-memory response cache keyed by hash(system + messages + provider/model)
- [x] Cancel support via `{"type":"cancel"}` WebSocket frame
- [x] Robust tool-call parser — accepts plain JSON, ```json fences, and embedded JSON blocks
- [x] Iteration limit raised to 12 with structured Thought→Tool→Observation loop
- [x] Flutter `AgentService` upgraded to render streaming tokens, live shell chunks,
      and finalised replies without duplicate bubbles

### Phase 5b — Sidebar overlay [✅ Complete]
- [x] Sidebar now floats over the editor (Stack + slide animation + scrim) instead
      of pushing the editor canvas — fixes editor overflow on narrow screens

### Phase 5c — Build artefact API [✅ Complete]
- [x] FastAPI backend at `/api/download` serves a marigold "Editorial Terminal" download page
- [x] `/api/download/zip` streams `omni-ide.zip` (Flutter app + Android + agent + scripts + workflows)
- [x] `/api/manifest` returns the bundled-file inventory as JSON
- [x] Public preview URL: `https://048efec3-e15d-4f14-9823-7e7e99fcccb6.preview.emergentagent.com/api/download`

### Phase 6 — Real File Explorer [✅ Complete]

### Phase 7 — Real Terminal
- Flutter ↔ Termux shell via WebSocket
- xterm-compatible rendering
- Persistent session tabs

### Phase 8 — Git integration
- Status / diff / commit / push in a visual panel

### Phase 9 — Live preview
- WebView pointing to `localhost:PORT` when running a dev server

### Phase 10 — Plugin system
- Allow users to register custom tools
