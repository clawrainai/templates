#!/bin/bash
# ClawRain Agent Setup Script v7
# Architecture: OpenClaw + Senpi MCP
# - Each strategy has its own ~/.config/senpi/ (credentials, wallet, state)
# - Optional --start flag with systemd service
# 
# Usage:
#   curl ...setup.sh | bash -s -- --agent-id ID
#   curl ...setup.sh | bash -s -- --agent-id ID --start

set -e

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }
log_done()  { echo -e "${CYAN}[DONE]${NC} $1"; }

# ─── Repos ─────────────────────────────────────────────────────────────────
SENPI_UPSTREAM="https://github.com/Senpi-ai/senpi-skills"
SENPI_MCP_ENDPOINT="https://mcp.prod.senpi.ai"

usage() {
  echo "Usage:"
  echo "  curl ...setup.sh | bash -s -- --agent-id ID"
  echo "  curl ...setup.sh | bash -s -- --agent-id ID --start"
  echo ""
  echo "Options:"
  echo "  --agent-id      ClawRain agent UUID (required)"
  echo "  --start         Auto-start the agent after setup"
  echo "  --workspace     Custom workspace directory"
  echo "  --identity      Identity: telegram, wallet, or agent (default: agent)"
  echo "  --identity-val  Identity value (@username or 0x address)"
  exit 1
}

# ─── Args ──────────────────────────────────────────────────────────────────
AGENT_ID=""
AUTO_START=false
WORKSPACE_DIR=""
IDENTITY_TYPE="agent"
IDENTITY_VALUE=""
STARTUP_TOKEN=""  # Token for auto-start via systemd

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-id)     AGENT_ID="$2";      shift 2 ;;
    --start)        AUTO_START=true;     shift ;;
    --workspace)    WORKSPACE_DIR="$2";   shift 2 ;;
    --identity)     IDENTITY_TYPE="$2";   shift 2 ;;
    --identity-val) IDENTITY_VALUE="$2"; shift 2 ;;
    --startup-token) STARTUP_TOKEN="$2";  shift 2 ;;
    --help)         usage ;;
    *)              log_error "Unknown: $1"; usage ;;
  esac
done

# ─── Validate ──────────────────────────────────────────────────────────────
[[ -z "$AGENT_ID" ]] && { log_error "--agent-id required"; usage; }

# ─── Load config ──────────────────────────────────────────────────────────
if [[ -z "$CLAWRAIN_CONFIG" ]]; then
  log_error "CLAWRAIN_CONFIG env var not set. Run via Hub API URL."
  exit 1
fi

CONFIG_PATH="/tmp/agent-config-$AGENT_ID.json"
echo "$CLAWRAIN_CONFIG" | base64 -d > "$CONFIG_PATH"

PLATFORM_URL=$(jq -r '.platform_url // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform_endpoint // empty' "$CONFIG_PATH")
SKILL_REPO=$(jq -r '.skill.repo // "https://github.com/Senpi-ai/senpi-skills"' "$CONFIG_PATH")
SKILL_PATH=$(jq -r '.skill.path // empty' "$CONFIG_PATH")
SKILL_BRANCH=$(jq -r '.skill.branch // "main"' "$CONFIG_PATH")
STRATEGY=$(basename "$SKILL_PATH")

[[ -z "$STRATEGY" ]] && { log_error "strategy not found in config"; exit 1; }

STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]')
STRATEGY_UPPER=$(echo "$STRATEGY" | tr '[:lower:]' '[:upper:]')

# ─── Workspace ─────────────────────────────────────────────────────────────
# Each strategy has its own workspace, and its own ~/.config/senpi inside it
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace/clawrain/hyperliquid/senpi/$STRATEGY_KEBAB}"

# Per-strategy Senpi config (in workspace, not shared)
SENPI_CONFIG_DIR="$WORKSPACE_DIR/.config/senpi"
SENPI_CREDS="$SENPI_CONFIG_DIR/credentials.json"
SENPI_WALLET="$SENPI_CONFIG_DIR/wallet.json"
SENPI_STATE="$SENPI_CONFIG_DIR/state.json"

log_info "ClawRain Agent Setup v7"
log_info "Strategy: $STRATEGY_UPPER"
echo "========================================"
echo "  Agent ID:   $AGENT_ID"
echo "  Strategy:   $STRATEGY_UPPER"
echo "  Workspace:  $WORKSPACE_DIR"
echo "  Auto-start: $AUTO_START"
echo ""

# ─── Validate deps ──────────────────────────────────────────────────────────
command -v jq     &>/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
command -v git    &>/dev/null || { log_error "git required"; exit 1; }
command -v node   &>/dev/null || { log_error "node (Node.js) required"; exit 1; }

# ─── Ensure Node.js dependencies ───────────────────────────────────────────
# ethers is required for wallet generation
if ! node -e "require('ethers')" 2>/dev/null; then
  log_info "Installing ethers@6 (required for wallet generation)..."
  npm install -g ethers@6 --quiet 2>/dev/null || npm install -g ethers@6
fi
command -v mcporter &>/dev/null && MC_PORTER=true || MC_PORTER=false

# ─── STEP 1: Create workspace ──────────────────────────────────────────────
log_step "STEP 1: Creating workspace..."

mkdir -p "$WORKSPACE_DIR"/{skills,scripts,memory}
mkdir -p "$SENPI_CONFIG_DIR"
mkdir -p "$HOME/.openclaw/workspace/config"

log_done "Workspace: $WORKSPACE_DIR"

# ─── STEP 2: Clone senpi-skills ────────────────────────────────────────────
log_step "STEP 2: Cloning Senpi skills..."

SENPI_TMP="/tmp/senpi-skills-$AGENT_ID"
if [[ ! -d "$SENPI_TMP" ]]; then
  git clone --depth 1 "$SKILL_REPO" "$SENPI_TMP" 2>/dev/null || {
    log_error "Failed to clone $SKILL_REPO"
    exit 1
  }
fi

log_done "Senpi skills cloned"

# ─── STEP 3: Copy strategy ─────────────────────────────────────────────────
log_step "STEP 3: Installing strategy '$STRATEGY_UPPER'..."

STRATEGY_PATH="$SENPI_TMP/$SKILL_PATH"
if [[ ! -d "$STRATEGY_PATH" ]]; then
  log_error "Strategy not found at '$SKILL_PATH'"
  ls "$SENPI_TMP" | grep -v "senpi-\|dsl-\|\.md\|LICENSE" | head -20
  exit 1
fi

# Copy skill with proper structure (skills/polar-strategy/config/, etc.)
SKILL_NAME=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]')-strategy
mkdir -p "$WORKSPACE_DIR/skills/$SKILL_NAME"
cp -r "$STRATEGY_PATH"/* "$WORKSPACE_DIR/skills/$SKILL_NAME/" 2>/dev/null || true

# Copy skill README to workspace root for reference
cp "$STRATEGY_PATH/README.md" "$WORKSPACE_DIR/SKILL-README.md" 2>/dev/null || true

# Copy shared plugins
for plugin in dsl-dynamic-stop-loss fee-optimizer emerging-movers opportunity-scanner; do
  if [[ -d "$SENPI_TMP/$plugin/skills" ]]; then
    mkdir -p "$WORKSPACE_DIR/skills/$plugin"
    cp -r "$SENPI_TMP/$plugin/skills/"* "$WORKSPACE_DIR/skills/$plugin/" 2>/dev/null || true
  fi
done

log_done "Strategy installed"

# ─── STEP 4: Generate wallet ───────────────────────────────────────────────
log_step "STEP 4: Generating wallet..."

WALLET_SCRIPT="$SENPI_TMP/senpi-onboard/scripts/generate_wallet.js"
WALLET_DATA=""
if [[ -f "$WALLET_SCRIPT" ]]; then
  # Try with NODE_PATH if ethers is installed globally
  WALLET_DATA=$(NODE_PATH=$(npm root -g) node "$WALLET_SCRIPT" 2>/dev/null)
fi

if [[ -z "$WALLET_DATA" ]]; then
  # Try inline with global ethers
  WALLET_DATA=$(NODE_PATH=$(npm root -g) node -e "
    const { ethers } = require('ethers');
    const w = ethers.Wallet.createRandom();
    console.log(JSON.stringify({ address: w.address, privateKey: w.privateKey, mnemonic: w.mnemonic.phrase }));
  " 2>/dev/null)
fi

if [[ -z "$WALLET_DATA" ]]; then
  # Last resort: use npx
  WALLET_DATA=$(npx -y -p ethers@6 node -e "
    const { ethers } = require('ethers');
    const w = ethers.Wallet.createRandom();
    console.log(JSON.stringify({ address: w.address, privateKey: w.privateKey, mnemonic: w.mnemonic.phrase }));
  " 2>/dev/null)
fi

if [[ -n "$WALLET_DATA" ]]; then
  WALLET_ADDR=$(echo "$WALLET_DATA" | jq -r '.address')
  echo "$WALLET_DATA" > "$SENPI_WALLET"
  chmod 600 "$SENPI_WALLET"
  log_done "Wallet: ${WALLET_ADDR:0:10}...${WALLET_ADDR: -6}"
else
  log_error "Wallet generation failed — no ethers available"
  log_error "Please install: npm install -g ethers@6"
fi

# ─── STEP 5: Register with Senpi ───────────────────────────────────────────
log_step "STEP 5: Registering with Senpi..."

case "$IDENTITY_TYPE" in
  telegram)
    IDENTITY_FROM="TELEGRAM"
    IDENTITY_SUBJECT="${IDENTITY_VALUE#@}"
    ;;
  wallet)
    IDENTITY_FROM="WALLET"
    IDENTITY_SUBJECT="$IDENTITY_VALUE"
    ;;
  agent|*)
    IDENTITY_FROM="WALLET"
    IDENTITY_SUBJECT="${WALLET_ADDR:-$(cat $SENPI_WALLET 2>/dev/null | jq -r '.address')}"
    ;;
esac

RESPONSE=$(curl -s -X POST https://moxie-backend.prod.senpi.ai/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation CreateAgentStubAccount($input: CreateAgentStubAccountInput!) { CreateAgentStubAccount(input: $input) { user { id userName referralCode } apiKey apiKeyExpiresIn apiKeyTokenType agentWalletAddress } }",
    "variables": {
      "input": {
        "from": "'"${IDENTITY_FROM}"'",
        "subject": "'"${IDENTITY_SUBJECT}"'",
        "referralCode": "",
        "apiKeyName": "agent-'"$(date +%s)"'"
      }
    }
  }')

if echo "$RESPONSE" | jq -e '.data.CreateAgentStubAccount.apiKey' >/dev/null 2>&1; then
  SENPI_API_KEY=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.apiKey')
  SENPI_USER_ID=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.user.id')
  SENPI_REFERRAL=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.user.referralCode')
  SENPI_WALLET_ADDR=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.agentWalletAddress')
  
  cat > "$SENPI_CREDS" << EOF
{
  "apiKey": "$SENPI_API_KEY",
  "userId": "$SENPI_USER_ID",
  "referralCode": "$SENPI_REFERRAL",
  "agentWalletAddress": "$SENPI_WALLET_ADDR",
  "onboardedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "onboardedVia": "$IDENTITY_FROM",
  "subject": "$IDENTITY_SUBJECT"
}
EOF
  chmod 600 "$SENPI_CREDS"
  
  log_done "Senpi registered: User $SENPI_USER_ID"
else
  log_warn "Senpi API registration failed"
  SENPI_API_KEY=""
  SENPI_USER_ID="unknown"
  SENPI_REFERRAL=""
fi

# ─── STEP 6: Configure MCP ─────────────────────────────────────────────────
log_step "STEP 6: Configuring Senpi MCP..."

if $MC_PORTER && [[ -n "$SENPI_API_KEY" ]]; then
  mcporter config add senpi-$STRATEGY_KEBAB --command npx \
    --persist "$HOME/.openclaw/workspace/config/mcporter-$STRATEGY_KEBAB.json" \
    --env "SENPI_AUTH_TOKEN=${SENPI_API_KEY}" \
    -- mcp-remote "${SENPI_MCP_ENDPOINT}/mcp" \
    --header "Authorization: Bearer \${SENPI_AUTH_TOKEN}" 2>/dev/null || {
    log_warn "mcporter failed, using .mcp.json"
    MC_PORTER=false
  }
fi

if ! $MC_PORTER; then
  cat > "$WORKSPACE_DIR/.mcp.json" << EOF
{
  "mcpServers": {
    "senpi": {
      "command": "npx",
      "args": ["mcp-remote", "${SENPI_MCP_ENDPOINT}/mcp", "--header", "Authorization: Bearer \${SENPI_AUTH_TOKEN}"],
      "env": { "SENPI_AUTH_TOKEN": "${SENPI_API_KEY}" }
    }
  }
}
EOF
fi

log_done "MCP configured"

# ─── STEP 7: Create identity files ─────────────────────────────────────────
log_step "STEP 7: Creating agent identity..."

cat > "$WORKSPACE_DIR/SOUL.md" << EOF
# SOUL.md — $STRATEGY_UPPER Trading Agent

I am **$STRATEGY_UPPER**, an autonomous trading agent powered by Senpi + Hyperliquid.

## My Mission

Execute the $STRATEGY_UPPER strategy with discipline and risk management.

## Strategy

$(cat "$STRATEGY_PATH"/README.md 2>/dev/null | head -50 || echo "See skills/ directory")

## Identity

- **Strategy**: $STRATEGY_UPPER
- **Exchange**: Hyperliquid
- **Operator**: ClawRain Hub
- **Created**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

cat > "$WORKSPACE_DIR/AGENTS.md" << 'AGENTS'
# AGENTS.md

## Memory
- Daily logs in memory/YYYY-MM-DD.md
- Decisions in memory/decisions/
- Lessons in memory/lessons/

## Safety Rules
- DSL High Water Mode is MANDATORY
- Never trade without stop loss
- Report all trades to platform
AGENTS

cat > "$WORKSPACE_DIR/IDENTITY.md" << EOF
# IDENTITY.md
- **Name**: $STRATEGY_UPPER
- **Type**: Autonomous Trading Agent
- **Emoji**: 🤖
- **Created**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log_done "Identity created"

# ─── STEP 8: Initialize state ──────────────────────────────────────────────
log_step "STEP 8: Initializing state..."

cat > "$SENPI_STATE" << EOF
{
  "version": "1.0.0",
  "state": "UNFUNDED",
  "strategy": "$STRATEGY_UPPER",
  "workspace": "$WORKSPACE_DIR",
  "onboarding": {
    "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "account": {
    "userId": "${SENPI_USER_ID:-unknown}",
    "referralCode": "${SENPI_REFERRAL:-unknown}"
  },
  "wallet": {
    "address": "${WALLET_ADDR:-unknown}",
    "funded": false
  }
}
EOF

log_done "State initialized"

# ─── STEP 9: Create start script ────────────────────────────────────────────
log_step "STEP 9: Creating start script..."

cat > "$WORKSPACE_DIR/start.sh" << 'STARTSCRIPT'
#!/bin/bash
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_NAME="$(basename "$AGENT_DIR")"

# Load Senpi credentials for this strategy (parse JSON with jq)
SENPI_CONFIG="$AGENT_DIR/.config/senpi"
if [[ -f "$SENPI_CONFIG/credentials.json" ]]; then
  export SENPI_AUTH_TOKEN="$(jq -r '.apiKey' "$SENPI_CONFIG/credentials.json" 2>/dev/null)"
  export SENPI_API_KEY="$SENPI_AUTH_TOKEN"
fi

echo "========================================"
echo "  ClawRain Agent: $AGENT_NAME"
echo "  Workspace: $AGENT_DIR"
echo "  Started: $(date)"
echo "========================================"

# Verify credentials exist
if [[ ! -f "$SENPI_CONFIG/credentials.json" ]]; then
  echo "ERROR: Senpi credentials not found"
  exit 1
fi

# Set OpenClaw workspace so Senpi scripts find their skills/config
export OPENCLAW_WORKSPACE="$AGENT_DIR"

# Start OpenClaw agent
cd "$AGENT_DIR"
exec openclaw agent
STARTSCRIPT

chmod +x "$WORKSPACE_DIR/start.sh"

log_done "Start script created"

# ─── STEP 10: Create systemd service (auto-start) ───────────────────────────
if [[ "$AUTO_START" == "true" ]]; then
  log_step "STEP 10: Creating systemd service..."
  
  SYSTEMD_UNIT="$HOME/.config/systemd/user/clawrain-$STRATEGY_KEBAB.service"
  mkdir -p "$(dirname "$SYSTEMD_UNIT")"
  
  cat > "$SYSTEMD_UNIT" << EOF
[Unit]
Description=ClawRain $STRATEGY_UPPER Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKSPACE_DIR
Environment="OPENCLAW_WORKSPACE=$WORKSPACE_DIR"
Environment="SENPI_AUTH_TOKEN=$(cat $SENPI_CREDS 2>/dev/null | jq -r '.apiKey')"
ExecStart=$WORKSPACE_DIR/start.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

  # Enable lingering for non-login users
  log_done "Systemd service created"
fi

# ─── STEP 11: Register with platform ───────────────────────────────────────
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_step "STEP 11: Registering with platform..."
  
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_metrics" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "apikey: $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"strategy\":\"$STRATEGY_UPPER\",\"status\":\"provisioned\",\"equity\":0,\"pnl_total\":0}" \
    || log_warn "Platform registration failed"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$SENPI_TMP"
rm -f "$CONFIG_PATH"

# ─── Auto-start if requested ──────────────────────────────────────────────
if [[ "$AUTO_START" == "true" ]]; then
  log_step "STARTING: Agent $STRATEGY_UPPER..."
  
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable clawrain-$STRATEGY_KEBAB 2>/dev/null || true
  systemctl --user start clawrain-$STRATEGY_KEBAB 2>/dev/null || true
  
  sleep 2
  if systemctl --user is-active --quiet clawrain-$STRATEGY_KEBAB 2>/dev/null; then
    log_done "Agent $STRATEGY_UPPER is running!"
  else
    log_warn "Could not verify agent status"
  fi
fi

# ─── DONE ──────────────────────────────────────────────────────────────────
echo ""
log_info "========================================"
log_info "✅ Setup complete!"
log_info "========================================"
echo ""
echo "  Strategy:   $STRATEGY_UPPER"
echo "  Workspace:  $WORKSPACE_DIR"
echo "  Wallet:     ${WALLET_ADDR:0:10}...${WALLET_ADDR: -6}"
echo ""
echo "Next step:"
echo "  Fund wallet: ${WALLET_ADDR:-unknown}"
echo ""
if [[ "$AUTO_START" != "true" ]]; then
  echo "  To start:   $WORKSPACE_DIR/start.sh"
  echo "  To auto-start: re-run with --start flag"
fi
echo ""
