#!/data/data/com.termux/files/usr/bin/bash

# ============================================
# Omni-IDE Termux Environment Setup Script
# ============================================
# Run this script inside Termux to set up the
# full agent environment with all dependencies.
#
# Usage:
#   bash scripts/setup_termux.sh
#
# Or remotely:
#   bash <(curl -sL https://raw.githubusercontent.com/M7mD0X/theomni/main/scripts/setup_termux.sh)
# ============================================

set -e  # Stop on any error

OMNI_DIR="$HOME/omni-ide"
AGENT_DIR="$OMNI_DIR/agent"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_AGENT_DIR="$REPO_DIR/agent"

echo "Starting Omni-IDE Environment Setup..."

# ---- Step 1: Update packages ----
echo "Updating Termux packages..."
pkg update -y && pkg upgrade -y

# ---- Step 2: Install core tools ----
echo "Installing core tools..."
pkg install -y \
  nodejs \
  git \
  python \
  openssh \
  curl \
  wget

# ---- Step 3: Verify installs ----
echo "Verifying installations..."
node --version || { echo "Node.js failed"; exit 1; }
npm --version  || { echo "npm failed"; exit 1; }
git --version  || { echo "Git failed"; exit 1; }

# ---- Step 4: Create project structure ----
echo "Creating Omni-IDE directory structure..."
mkdir -p "$OMNI_DIR/projects"
mkdir -p "$OMNI_DIR/logs"

# ---- Step 5: Set up the agent ----
echo "Setting up Agent..."

# Try to copy from repo first (if running from a cloned repo)
if [ -d "$REPO_AGENT_DIR" ] && [ -f "$REPO_AGENT_DIR/agent.js" ]; then
  echo "Found agent in repo at $REPO_AGENT_DIR"
  # Remove old agent dir if it exists
  rm -rf "$AGENT_DIR"
  # Copy the entire agent directory (including lib/)
  cp -r "$REPO_AGENT_DIR" "$AGENT_DIR"
  echo "Copied agent from repo."
else
  # No local repo — clone from GitHub
  echo "No local agent found. Cloning from GitHub..."
  if command -v git &>/dev/null; then
    TEMP_CLONE="$(mktemp -d)"
    git clone --depth 1 https://github.com/M7mD0X/theomni.git "$TEMP_CLONE/theomni" 2>/dev/null || {
      echo "Failed to clone repository. Check your internet connection."
      rm -rf "$TEMP_CLONE"
      exit 1
    }
    rm -rf "$AGENT_DIR"
    cp -r "$TEMP_CLONE/theomni/agent" "$AGENT_DIR"
    rm -rf "$TEMP_CLONE"
    echo "Cloned agent from GitHub."
  else
    echo "Git not available. Cannot download agent."
    exit 1
  fi
fi

# Verify agent exists
if [ ! -f "$AGENT_DIR/agent.js" ]; then
  echo "Error: agent.js not found at $AGENT_DIR"
  exit 1
fi

# ---- Step 6: Install Node dependencies ----
echo "Installing Node.js dependencies..."
cd "$AGENT_DIR"
npm install --production 2>/dev/null || npm install 2>/dev/null

# ---- Step 7: Create start script ----
cat > "$OMNI_DIR/start_agent.sh" << 'STARTSCRIPT'
#!/data/data/com.termux/files/usr/bin/bash
# Omni-IDE Agent Launcher
# Usage: ~/omni-ide/start_agent.sh

set -euo pipefail

AGENT_DIR="$HOME/omni-ide/agent"
PID_FILE="$HOME/omni-ide/agent.pid"
LOG_DIR="$HOME/omni-ide/logs"
LOG_FILE="$LOG_DIR/agent.log"
PORT="${OMNI_PORT:-8080}"
MAX_RESTARTS=5

# Create directories if they don't exist
mkdir -p "$LOG_DIR" "$HOME/omni-ide"

# Log rotation
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 524288 ]; then
    tail -c 262144 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
fi

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }

# Fast path: already running?
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

# Verify agent directory exists
if [ ! -f "$AGENT_DIR/agent.js" ]; then
    echo "Error: Agent not found at $AGENT_DIR/agent.js"
    echo "Run setup first: bash scripts/setup_termux.sh"
    exit 1
fi

# Start with auto-restart
log "Starting agent..."
cd "$AGENT_DIR"

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
STARTSCRIPT
chmod +x "$OMNI_DIR/start_agent.sh"

# ---- Done ----
echo ""
echo "Omni-IDE Environment Setup Complete!"
echo "  Project dir: $OMNI_DIR"
echo "  Agent dir:   $AGENT_DIR"
echo "  Start agent: ~/omni-ide/start_agent.sh"
echo ""
echo "Test agent: curl http://localhost:8080/ping"
