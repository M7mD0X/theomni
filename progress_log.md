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

## Phase 4 — UI/UX Full Overhaul [✅ This session]
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
### Phase 5 — Better AI Agent (planned)
- Streaming responses (token-by-token reveal)
- Richer tool set: grep_in_files, patch_file (diff-based edits), run_shell with live stdout, git_* tools
- Response caching + retry with backoff
- Proper system prompt with project context awareness
- Tool call visualisation with expandable diff views

### Phase 6 — Real File Explorer (planned)
- Browse any directory (not just `~/omni-ide/projects`)
- File create / rename / delete / move from Flutter
- Drag-to-reorder
- File search (global grep)

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
