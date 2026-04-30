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
#   2. Ensures the omni-ide directory structure exists
#   3. Installs Node.js if missing (pkg install nodejs)
#   4. Downloads the agent from GitHub if not present locally
#   5. Installs npm dependencies if missing
#   6. Starts the agent in the background
# =====================================================================

set -euo pipefail

PORT="${OMNI_PORT:-8080}"
OMNI_DIR="$HOME/omni-ide"
AGENT_DIR="$OMNI_DIR/agent"

# Resolve repo agent dir (if running from a cloned repo)
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
REPO_AGENT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/agent/agent.js" ]; then
  REPO_AGENT_DIR="$SCRIPT_DIR/agent"
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../agent/agent.js" ]; then
  REPO_AGENT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "")/agent"
fi

# ── Fast path: already running? ─────────────────────────────────────────────
if command -v curl &>/dev/null && curl -sf "http://localhost:$PORT/health" &>/dev/null; then
    echo "Agent already running on :$PORT"
    exit 0
fi

# ── Ensure directory structure ──────────────────────────────────────────────
mkdir -p "$OMNI_DIR/projects" "$OMNI_DIR/logs"

# ── Prerequisites ───────────────────────────────────────────────────────────
echo "Checking prerequisites..."

if ! command -v node &>/dev/null; then
    echo "Installing Node.js..."
    pkg install -y nodejs 2>/dev/null || { echo "Install Node.js first: pkg install nodejs"; exit 1; }
fi

# ── Ensure agent files exist ────────────────────────────────────────────────
if [ ! -f "$AGENT_DIR/agent.js" ]; then
    echo "Agent not found at $AGENT_DIR"

    # Try copying from local repo
    if [ -n "$REPO_AGENT_DIR" ] && [ -f "$REPO_AGENT_DIR/agent.js" ]; then
        echo "Copying agent from repo..."
        cp -r "$REPO_AGENT_DIR" "$AGENT_DIR"
    else
        # Download from GitHub
        echo "Downloading agent from GitHub..."
        if command -v git &>/dev/null; then
            TEMP_CLONE="$(mktemp -d)"
            git clone --depth 1 https://github.com/M7mD0X/theomni.git "$TEMP_CLONE/theomni" 2>/dev/null || {
                echo "Failed to clone. Check internet connection."
                rm -rf "$TEMP_CLONE"
                exit 1
            }
            cp -r "$TEMP_CLONE/theomni/agent" "$AGENT_DIR"
            rm -rf "$TEMP_CLONE"
        else
            echo "Git not available. Install it: pkg install git"
            echo "Or run setup first: bash scripts/setup_termux.sh"
            exit 1
        fi
    fi
fi

# Verify the agent file exists now
if [ ! -f "$AGENT_DIR/agent.js" ]; then
    echo "Error: Could not set up agent at $AGENT_DIR"
    exit 1
fi

# ── Install dependencies ────────────────────────────────────────────────────
if [ ! -d "$AGENT_DIR/node_modules" ]; then
    echo "Installing dependencies..."
    cd "$AGENT_DIR" && npm install --production 2>/dev/null
fi

# ── Create start script if missing ──────────────────────────────────────────
if [ ! -f "$OMNI_DIR/start_agent.sh" ]; then
    cat > "$OMNI_DIR/start_agent.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
AGENT_DIR="$HOME/omni-ide/agent"
LOG_DIR="$HOME/omni-ide/logs"
mkdir -p "$LOG_DIR"
nohup node "$AGENT_DIR/agent.js" >> "$LOG_DIR/agent.log" 2>&1 &
echo $! > "$HOME/omni-ide/agent.pid"
echo "Agent started (PID: $!)"
EOF
    chmod +x "$OMNI_DIR/start_agent.sh"
fi

# ── Launch ─────────────────────────────────────────────────────────────────
echo "Starting agent..."
cd "$AGENT_DIR"

# Run via nohup in background
nohup node agent.js >> "$HOME/omni-ide/logs/agent.log" 2>&1 &
PID=$!
echo "$PID" > "$HOME/omni-ide/agent.pid"

# Wait for health (up to 10s)
echo "Waiting for agent..."
for i in $(seq 1 10); do
    sleep 1
    if curl -sf "http://localhost:$PORT/health" &>/dev/null; then
        echo "Agent started on :$PORT (PID: $PID)"
        exit 0
    fi
done

echo "Agent didn't start in 10s — check ~/omni-ide/logs/agent.log"
exit 1
