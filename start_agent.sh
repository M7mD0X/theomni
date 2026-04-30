#!/data/data/com.termux/files/usr/bin/bash
# =====================================================================
# Omni-IDE Agent Startup Script (v8)
# =====================================================================
# Professional agent launcher with:
#   - Single-instance guarantee (PID file + health check)
#   - Auto-restart with exponential backoff (5 max)
#   - Log rotation (keeps last 512KB)
#   - Graceful shutdown on SIGTERM/SIGINT
#   - Fast path: if agent is healthy, exits immediately
#   - Proper path resolution from multiple install locations
# =====================================================================

set -euo pipefail

# Resolve agent directory — check multiple locations
# 1. Installed location: ~/omni-ide/agent/
# 2. Relative to this script's location (repo checkout)
# 3. Fallback to default

_find_agent_dir() {
    # Check installed location first
    if [ -f "$HOME/omni-ide/agent/agent.js" ]; then
        echo "$HOME/omni-ide/agent"
        return
    fi

    # Check relative to script location
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    if [ -f "$script_dir/agent/agent.js" ]; then
        echo "$script_dir/agent"
        return
    fi

    # Check if script is inside omni-ide dir
    if [ -f "$script_dir/agent.js" ]; then
        echo "$script_dir"
        return
    fi

    # Default
    echo "$HOME/omni-ide/agent"
}

AGENT_DIR="$(_find_agent_dir)"
PID_FILE="$HOME/omni-ide/agent.pid"
LOG_DIR="$HOME/omni-ide/logs"
LOG_FILE="$LOG_DIR/agent.log"
PORT="${OMNI_PORT:-8080}"
MAX_RESTARTS=5

# ── Setup ─────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$HOME/omni-ide"

# Log rotation
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
    tail -c 262144 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }

# ── Verify agent exists ────────────────────────────────────────────────────
if [ ! -f "$AGENT_DIR/agent.js" ]; then
    echo "Error: Agent not found at $AGENT_DIR/agent.js"
    echo "Run setup first: bash scripts/setup_termux.sh"
    echo "Or quick start:  bash quick_start.sh"
    exit 1
fi

# ── Fast path: already running? ───────────────────────────────────────────
if command -v curl &>/dev/null && curl -sf "http://localhost:$PORT/health" &>/dev/null; then
    log "Agent already running on :$PORT"
    echo "Agent already running on :$PORT"
    exit 0
fi

# Kill stale process
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "Killing stale process $pid"
        kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

# ── Start with auto-restart ───────────────────────────────────────────────
log "Starting agent from $AGENT_DIR ..."
cd "$AGENT_DIR"

# Ensure node_modules exist
if [ ! -d "node_modules" ]; then
    log "Installing dependencies..."
    npm install --production 2>/dev/null || npm install 2>/dev/null || true
fi

restarts=0
delay=2

cleanup() {
    log "Shutdown signal"
    [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup SIGTERM SIGINT

while [ $restarts -lt $MAX_RESTARTS ]; do
    log "Attempt $((restarts + 1))/$MAX_RESTARTS"
    node agent.js >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    # Wait for health (up to 12s)
    waited=0
    while [ $waited -lt 12 ]; do
        sleep 1; waited=$((waited + 1))
        if curl -sf "http://localhost:$PORT/health" &>/dev/null; then
            log "Healthy on :$PORT (PID: $(cat "$PID_FILE"))"
            echo "Agent started on :$PORT"
            wait "$(cat "$PID_FILE")" 2>/dev/null || true
            restarts=$((restarts + 1))
            delay=2
            continue 2
        fi
    done

    # Failed to start
    restarts=$((restarts + 1))
    if [ $restarts -lt $MAX_RESTARTS ]; then
        log "Retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))
    fi
done

log "Max restarts reached"
echo "Agent failed after $MAX_RESTARTS attempts"
rm -f "$PID_FILE"
exit 1
