#!/bin/bash
# ClawRain Agent Setup Script v6
# Architecture: OpenClaw + Senpi MCP (no Python agent)
# 
# Usage:
#   curl ...setup.sh | bash -s -- --agent-id ID --strategy POLAR

set -e

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ─── Repos ─────────────────────────────────────────────────────────────────
SENPI_UPSTREAM="https://github.com/Senpi-ai/senpi-skills"
SENPI_MCP_ENDPOINT="https://mcp.prod.senpi.ai"

usage() {
  echo "Usage:"
  echo "  curl ...setup.sh | bash -s -- --agent-id ID --strategy POLAR"
  echo ""
  echo "Required:"
  echo "  --agent-id      ClawRain agent UUID"
  echo "  --strategy      Strategy name (POLAR, FOX, ORCA, etc.)"
  echo ""
  echo "Optional:"
  echo "  --workspace     Workspace directory (default: auto)"
  echo "  --identity      Identity type: telegram, wallet, or agent (default: agent)"
  echo "  --identity-val  Identity value (@username or 0x address)"
  exit 1
}

# ─── Args ──────────────────────────────────────────────────────────────────
AGENT_ID=""
STRATEGY=""
WORKSPACE_DIR=""
IDENTITY_TYPE="agent"  # agent = generate wallet
IDENTITY_VALUE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-id)    AGENT_ID="$2";    shift 2 ;;
    --strategy)    STRATEGY="$2";    shift 2 ;;
    --workspace)   WORKSPACE_DIR="$2"; shift 2 ;;
    --identity)    IDENTITY_TYPE="$2"; shift 2 ;;
    --identity-val) IDENTITY_VALUE="$2"; shift 2 ;;
    --help)        usage ;;
    *)             log_error "Unknown: $1"; usage ;;
  esac
done

# ─── Validate ──────────────────────────────────────────────────────────────
[[ -z "$AGENT_ID" ]]   && { log_error "--agent-id required"; usage; }
[[ -z "$STRATEGY" ]]  && { log_error "--strategy required (POLAR, FOX, ORCA...)"; usage; }

STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]')
STRATEGY_UPPER=$(echo "$STRATEGY" | tr '[:lower:]' '[:upper:]')

# ─── Load config from CLAWRAIN_CONFIG (embedded JSON) ───────────────────────
if [[ -z "$CLAWRAIN_CONFIG" ]]; then
  log_error "CLAWRAIN_CONFIG env var not set. Run via Hub API URL."
  exit 1
fi

CONFIG_PATH="/tmp/agent-config-$AGENT_ID.json"
echo "$CLAWRAIN_CONFIG" | base64 -d > "$CONFIG_PATH"

# Parse embedded config
PLATFORM_URL=$(jq -r '.platform_url // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform_endpoint // empty' "$CONFIG_PATH")
SKILL_REPO=$(jq -r '.skill.repo // "https://github.com/Senpi-ai/senpi-skills"' "$CONFIG_PATH")
SKILL_PATH=$(jq -r '.skill.path // empty' "$CONFIG_PATH")
SKILL_BRANCH=$(jq -r '.skill.branch // "main"' "$CONFIG_PATH")

# Override strategy from args
if [[ -n "$SKILL_PATH" ]]; then
  STRATEGY_KEBAB=$(basename "$SKILL_PATH" | tr '[:upper:]' '[:lower:]')
  STRATEGY_UPPER=$(echo "$STRATEGY_KEBAB" | tr '[:lower:]' '[:upper:]')
fi

# ─── Workspace ─────────────────────────────────────────────────────────────
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace/hyperliquid/senpi/$STRATEGY_KEBAB}"

log_info "ClawRain Agent Setup v6"
log_info "Strategy: $STRATEGY_UPPER"
echo "========================================"
echo "  Agent ID:   $AGENT_ID"
echo "  Strategy:   $STRATEGY_UPPER"
echo "  Workspace:  $WORKSPACE_DIR"
echo ""

# ─── Validate deps ──────────────────────────────────────────────────────────
command -v jq     &>/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
command -v git    &>/dev/null || { log_error "git required"; exit 1; }
command -v node  &>/dev/null || { log_error "node (Node.js) required"; exit 1; }
command -v mcporter &>/dev/null && MC_PORTER=true || MC_PORTER=false

# ─── STEP 1: Create workspace structure ─────────────────────────────────────
log_step "STEP 1: Creating workspace structure..."

mkdir -p "$WORKSPACE_DIR"/{skills,scripts,memory}
mkdir -p "$HOME/.config/senpi"
mkdir -p "$HOME/.openclaw/workspace/config"

log_info "Workspace: $WORKSPACE_DIR"

# ─── STEP 2: Clone senpi-skills ────────────────────────────────────────────
log_step "STEP 2: Cloning Senpi skills repository..."

SENPI_TMP="/tmp/senpi-skills-$AGENT_ID"

if [[ -d "$SENPI_TMP" ]]; then
  log_info "Using cached senpi-skills..."
else
  git clone --depth 1 "$SKILL_REPO" "$SENPI_TMP" 2>/dev/null || {
    log_error "Failed to clone $SKILL_REPO"
    exit 1
  }
fi

log_info "Senpi skills cloned"

# ─── STEP 3: Verify strategy exists ─────────────────────────────────────────
log_step "STEP 3: Verifying strategy '$STRATEGY_UPPER'..."

STRATEGY_PATH="$SENPI_TMP/$SKILL_PATH"
if [[ ! -d "$STRATEGY_PATH" ]]; then
  log_error "Strategy not found at '$SKILL_PATH'"
  log_info "Available strategies:"
  ls -d "$SENPI_TMP"/*/ 2>/dev/null | xargs -I{} basename {} | grep -v "senpi-\|dsl-\|emerging\|fee\|opportunity" | head -20
  rm -rf "$SENPI_TMP"
  exit 1
fi

# Copy strategy into workspace
cp -r "$STRATEGY_PATH"/skills/* "$WORKSPACE_DIR/skills/" 2>/dev/null || true
cp "$STRATEGY_PATH"/*.md "$WORKSPACE_DIR/" 2>/dev/null || true
cp "$STRATEGY_PATH"/*.json "$WORKSPACE_DIR/" 2>/dev/null || true

log_info "Strategy copied: $STRATEGY_PATH"

# Copy shared plugins (DSL, fee optimizer, etc.)
for plugin in dsl-dynamic-stop-loss fee-optimizer emerging-movers opportunity-scanner; do
  if [[ -d "$SENPI_TMP/$plugin/skills" ]]; then
    mkdir -p "$WORKSPACE_DIR/skills/$plugin"
    cp -r "$SENPI_TMP/$plugin/skills/"* "$WORKSPACE_DIR/skills/$plugin/" 2>/dev/null || true
  fi
done

# ─── STEP 4: Generate wallet ───────────────────────────────────────────────
log_step "STEP 4: Generating trading wallet..."

WALLET_SCRIPT="$SENPI_TMP/senpi-onboard/scripts/generate_wallet.js"
if [[ -f "$WALLET_SCRIPT" ]]; then
  WALLET_DATA=$(node "$WALLET_SCRIPT" 2>/dev/null) || {
    # Fallback inline generation
    WALLET_DATA=$(node -e "
      const { ethers } = require('ethers');
      const w = ethers.Wallet.createRandom();
      console.log(JSON.stringify({
        address: w.address,
        privateKey: w.privateKey,
        mnemonic: w.mnemonic.phrase
      }));
    " 2>/dev/null)
  }
  
  if [[ -n "$WALLET_DATA" ]]; then
    WALLET_ADDR=$(echo "$WALLET_DATA" | jq -r '.address')
    echo "$WALLET_DATA" > "$HOME/.config/senpi/wallet.json"
    chmod 600 "$HOME/.config/senpi/wallet.json"
    log_info "Wallet generated: ${WALLET_ADDR:0:10}...${WALLET_ADDR: -6}"
  fi
else
  log_warn "Wallet generation script not found"
fi

# ─── STEP 5: Senpi onboarding (API registration) ────────────────────────────
log_step "STEP 5: Registering with Senpi..."

# Prepare identity
case "$IDENTITY_TYPE" in
  telegram)
    IDENTITY_FROM="TELEGRAM"
    IDENTITY_SUBJECT="${IDENTITY_VALUE#@}"  # strip @
    ;;
  wallet)
    IDENTITY_FROM="WALLET"
    IDENTITY_SUBJECT="$IDENTITY_VALUE"
    ;;
  agent|*)
    IDENTITY_FROM="WALLET"
    IDENTITY_SUBJECT="${WALLET_ADDR:-$(cat $HOME/.config/senpi/wallet.json 2>/dev/null | jq -r '.address')}"
    ;;
esac

if [[ -z "$IDENTITY_SUBJECT" ]]; then
  log_error "Could not determine identity. Provide --identity wallet --identity-val 0x..."
  exit 1
fi

# Call Senpi GraphQL API
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

# Parse response
if echo "$RESPONSE" | jq -e '.data.CreateAgentStubAccount.apiKey' >/dev/null 2>&1; then
  SENPI_API_KEY=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.apiKey')
  SENPI_USER_ID=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.user.id')
  SENPI_REFERRAL=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.user.referralCode')
  SENPI_WALLET=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.agentWalletAddress')
  
  log_info "Senpi account created!"
  log_info "  User ID: $SENPI_USER_ID"
  log_info "  Referral: $SENPI_REFERRAL"
  
  # Save credentials
  cat > "$HOME/.config/senpi/credentials.json" << EOF
{
  "apiKey": "$SENPI_API_KEY",
  "userId": "$SENPI_USER_ID",
  "referralCode": "$SENPI_REFERRAL",
  "agentWalletAddress": "$SENPI_WALLET",
  "onboardedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "onboardedVia": "$IDENTITY_FROM",
  "subject": "$IDENTITY_SUBJECT"
}
EOF
  chmod 600 "$HOME/.config/senpi/credentials.json"
else
  log_warn "Senpi API registration failed: $(echo "$RESPONSE" | jq -r '.errors[0].message' 2>/dev/null || echo 'unknown error')"
  log_warn "Continuing anyway — manual registration possible later"
fi

# ─── STEP 6: Configure MCP server via mcporter ──────────────────────────────
log_step "STEP 6: Configuring Senpi MCP server..."

if $MC_PORTER && [[ -n "$SENPI_API_KEY" ]]; then
  log_info "Configuring mcporter for Senpi MCP..."
  
  mcporter config add senpi --command npx \
    --persist "$HOME/.openclaw/workspace/config/mcporter.json" \
    --env "SENPI_AUTH_TOKEN=${SENPI_API_KEY}" \
    -- mcp-remote "${SENPI_MCP_ENDPOINT}/mcp" \
    --header "Authorization: Bearer \${SENPI_AUTH_TOKEN}" 2>/dev/null || {
    log_warn "mcporter config failed — will use manual .mcp.json"
    $MC_PORTER=false
  }
fi

if ! $MC_PORTER; then
  log_info "Configuring via .mcp.json..."
  mkdir -p "$WORKSPACE_DIR"
  cat > "$WORKSPACE_DIR/.mcp.json" << EOF
{
  "mcpServers": {
    "senpi": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "${SENPI_MCP_ENDPOINT}/mcp",
        "--header",
        "Authorization: Bearer \${SENPI_AUTH_TOKEN}"
      ],
      "env": {
        "SENPI_AUTH_TOKEN": "${SENPI_API_KEY}"
      }
    }
  }
}
EOF
fi

log_info "MCP configured"

# ─── STEP 7: Create agent identity files ────────────────────────────────────
log_step "STEP 7: Creating agent identity..."

# SOUL.md - agent personality
cat > "$WORKSPACE_DIR/SOUL.md" << EOF
# SOUL.md — $STRATEGY_UPPER Trading Agent

I am **$STRATEGY_UPPER**, an autonomous trading agent running on Senpi + Hyperliquid.

## My Strategy

$(cat "$STRATEGY_PATH"/README.md 2>/dev/null | head -30 || echo "Strategy loaded from Senpi skills repository.")

## Core Identity

- **Role**: Autonomous Crypto Trader
- **Exchange**: Hyperliquid
- **Strategy**: $STRATEGY_UPPER
- **Operator**: ClawRain Hub

## Operational Loop

1. Scan markets using Senpi MCP tools
2. Evaluate signals per strategy criteria
3. Execute trades with proper position sizing
4. Monitor positions with DSL (Dynamic Stop Loss)
5. Report metrics to ClawRain Hub

## Safety Rules

- Never exceed configured risk parameters
- Always use DSL for active positions
- Report every trade to the platform
- Maintain trading log in memory/
EOF

# AGENTS.md - operational guidelines
cat > "$WORKSPACE_DIR/AGENTS.md" << 'AGENTS'
# AGENTS.md

## Memory
- Daily logs in memory/YYYY-MM-DD.md
- Decisions in memory/decisions/
- Lessons in memory/lessons/

## Skills
- Strategy: skills/$STRATEGY_KEBAB/
- Plugins: skills/dsl-*/, skills/fee-optimizer/, etc.

## Cron
- Market scan: every 3 minutes during market hours
- Portfolio check: every 15 minutes
- Performance report: daily

## Safety
- DSL High Water Mode is MANDATORY for all positions
- Never trade without stop loss
- Report all trades to platform
AGENTS

# IDENTITY.md
cat > "$WORKSPACE_DIR/IDENTITY.md" << EOF
# IDENTITY.md

- **Name**: $STRATEGY_UPPER
- **Type**: Autonomous Trading Agent
- **Emoji**: 🤖
- **Created**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log_info "Identity files created"

# ─── STEP 8: Create state.json ──────────────────────────────────────────────
log_step "STEP 8: Initializing Senpi state..."

cat > "$HOME/.config/senpi/state.json" << EOF
{
  "version": "1.0.0",
  "state": "UNFUNDED",
  "error": null,
  "onboarding": {
    "step": "COMPLETE",
    "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "identityType": "$IDENTITY_FROM",
    "subject": "$IDENTITY_SUBJECT",
    "walletGenerated": true
  },
  "account": {
    "userId": "${SENPI_USER_ID:-unknown}",
    "referralCode": "${SENPI_REFERRAL:-unknown}",
    "agentWalletAddress": "${SENPI_WALLET:-unknown}"
  },
  "wallet": {
    "address": "${WALLET_ADDR:-unknown}",
    "funded": false
  },
  "mcp": {
    "configured": true,
    "endpoint": "${SENPI_MCP_ENDPOINT}"
  }
}
EOF

log_info "State initialized"

# ─── STEP 9: Create start script ────────────────────────────────────────────
log_step "STEP 9: Creating start script..."

SENPI_CREDS="$HOME/.config/senpi/credentials.json"
SENPI_WALLET_FILE="$HOME/.config/senpi/wallet.json"

cat > "$WORKSPACE_DIR/start.sh" << 'STARTSCRIPT'
#!/bin/bash
# Start script for ClawRain trading agent

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_NAME="$(basename "$AGENT_DIR")"
SENPI_CREDS="$HOME/.config/senpi/credentials.json"
SENPI_WALLET="$HOME/.config/senpi/wallet.json"

echo "========================================"
echo "  ClawRain Agent: $AGENT_NAME"
echo "  Workspace: $AGENT_DIR"
echo "  Started: $(date)"
echo "========================================"

# Check credentials
if [[ ! -f "$SENPI_CREDS" ]]; then
  echo "ERROR: Senpi credentials not found at $SENPI_CREDS"
  echo "Run onboarding first."
  exit 1
fi

# Load API key for MCP
export SENPI_AUTH_TOKEN=$(cat "$SENPI_CREDS" | jq -r '.apiKey')

# Start OpenClaw agent
cd "$AGENT_DIR"
exec openclaw agent
STARTSCRIPT

chmod +x "$WORKSPACE_DIR/start.sh"

# ─── STEP 10: Register with platform ───────────────────────────────────────
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_step "STEP 10: Registering with ClawRain platform..."
  
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_metrics" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"strategy\":\"$STRATEGY_UPPER\",\"status\":\"provisioned\",\"equity\":0,\"pnl_total\":0}" \
    || log_warn "Could not register with platform"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$SENPI_TMP"
rm -f "$CONFIG_PATH"

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
echo "Next steps:"
echo "  1. Fund wallet: ${SENPI_WALLET:-$HOME/.config/senpi/wallet.json}"
echo "  2. Run: $WORKSPACE_DIR/start.sh"
echo ""
echo "Senpi referral: https://senpi.ai/skill.md?ref=${SENPI_REFERRAL:-}"
echo ""
