#!/data/data/com.termux/files/usr/bin/bash

# ============================================
# Omni-IDE Termux Environment Setup Script
# ============================================

set -e  # Stop on any error

OMNI_DIR="$HOME/omni-ide"
AGENT_DIR="$OMNI_DIR/agent"

echo "🚀 Starting Omni-IDE Environment Setup..."

# ---- Step 1: Update packages ----
echo "📦 Updating Termux packages..."
pkg update -y && pkg upgrade -y

# ---- Step 2: Install core tools ----
echo "🔧 Installing core tools..."
pkg install -y \
  nodejs \
  git \
  python \
  openssh \
  curl \
  wget

# ---- Step 3: Verify installs ----
echo "✅ Verifying installations..."
node --version || { echo "❌ Node.js failed"; exit 1; }
npm --version  || { echo "❌ npm failed"; exit 1; }
git --version  || { echo "❌ Git failed"; exit 1; }

# ---- Step 4: Create project structure ----
echo "📁 Creating Omni-IDE directory structure..."
mkdir -p "$AGENT_DIR"
mkdir -p "$OMNI_DIR/projects"
mkdir -p "$OMNI_DIR/logs"

# ---- Step 5: Create Node.js Agent skeleton ----
echo "🤖 Setting up Agent skeleton..."

cat > "$AGENT_DIR/package.json" << 'EOF'
{
  "name": "omni-ide-agent",
  "version": "1.0.0",
  "description": "Omni-IDE AI Agent",
  "main": "agent.js",
  "scripts": {
    "start": "node agent.js"
  },
  "dependencies": {
    "ws": "^8.16.0",
    "express": "^4.18.0"
  }
}
EOF

# ---- Step 6: Create Agent entry point ----
cat > "$AGENT_DIR/agent.js" << 'EOF'
const WebSocket = require('ws');
const express = require('express');

const app = express();
const PORT = 8080;

// HTTP health check
app.get('/ping', (req, res) => {
  res.json({ status: 'alive', agent: 'Omni-IDE', version: '1.0.0' });
});

const server = app.listen(PORT, () => {
  console.log(`[Agent] HTTP server on port ${PORT}`);
});

// WebSocket server for Flutter
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  console.log('[Agent] Flutter connected via WebSocket');
  
  ws.send(JSON.stringify({ 
    type: 'status', 
    message: 'Agent Ready' 
  }));

  ws.on('message', (data) => {
    const msg = JSON.parse(data);
    console.log('[Agent] Received:', msg);
    // TODO Phase 4: Route to AI tools
  });

  ws.on('close', () => {
    console.log('[Agent] Flutter disconnected');
  });
});

console.log('[Agent] Omni-IDE Agent started successfully');
EOF

# ---- Step 7: Install Node dependencies ----
echo "📦 Installing Node.js dependencies..."
cd "$AGENT_DIR"
npm install

# ---- Step 8: Create start script ----
cat > "$OMNI_DIR/start_agent.sh" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/omni-ide/agent
node agent.js >> ~/omni-ide/logs/agent.log 2>&1
EOF
chmod +x "$OMNI_DIR/start_agent.sh"

# ---- Done ----
echo ""
echo "✅ Omni-IDE Environment Setup Complete!"
echo "📂 Project dir: $OMNI_DIR"
echo "🤖 Agent dir:   $AGENT_DIR"
echo "▶️  Start agent: ~/omni-ide/start_agent.sh"
echo ""
echo "Test agent: curl http://localhost:8080/ping"