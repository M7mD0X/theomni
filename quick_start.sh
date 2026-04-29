#!/data/data/com.termux/files/usr/bin/bash
# =====================================================================
# Omni-IDE Quick Start — one-liner agent launcher
# =====================================================================
# Usage:
#   bash <(curl -sL https://raw.githubusercontent.com/M7mD0X/theomni/main/quick_start.sh)
#
# Or from an already-cloned repo:
#   bash quick_start.sh
#
# This script:
#   1. Checks if the agent is already running (instant exit if so)
#   2. Installs Node.js if missing (pkg install nodejs)
#   3. Installs npm dependencies if missing
#   4. Starts the agent in the background
# =====================================================================

set -euo pipefail

PORT="${OMNI_PORT:-8080}"
AGENT_DIR="$(cd "$(dirname "$0")/agent" 2>/dev/null && pwd)" || AGENT_DIR=""
[ -z "$AGENT_DIR" ] && AGENT_DIR="$HOME/omni-ide/agent"

# ── Fast path ─────────────────────────────────────────────────────────────
if command -v curl &>/dev/null && curl -sf "http://localhost:$PORT/health" &>/dev/null; then
    echo "✓ Agent already running on :$PORT"
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────
echo "• Checking prerequisites..."

if ! command -v node &>/dev/null; then
    echo "• Installing Node.js..."
    pkg install -y nodejs 2>/dev/null || { echo "✗ Install Node.js first: pkg install nodejs"; exit 1; }
fi

if [ ! -d "$AGENT_DIR" ] || [ ! -f "$AGENT_DIR/agent.js" ]; then
    echo "✗ Agent not found at $AGENT_DIR"
    echo "  Run setup first: bash scripts/setup_termux.sh"
    exit 1
fi

if [ ! -d "$AGENT_DIR/node_modules" ]; then
    echo "• Installing dependencies..."
    cd "$AGENT_DIR" && npm install --production 2>/dev/null
fi

# ── Launch ─────────────────────────────────────────────────────────────────
echo "• Starting agent..."
cd "$AGENT_DIR"

# Run via nohup in background
nohup node agent.js >> "$HOME/omni-ide/logs/agent.log" 2>&1 &
PID=$!
echo "$PID" > "$HOME/omni-ide/agent.pid"

# Wait for health (up to 10s)
echo "• Waiting for agent..."
for i in $(seq 1 10); do
    sleep 1
    if curl -sf "http://localhost:$PORT/health" &>/dev/null; then
        echo "✓ Agent started on :$PORT (PID: $PID)"
        exit 0
    fi
done

echo "✗ Agent didn't start in 10s — check ~/omni-ide/logs/agent.log"
exit 1
