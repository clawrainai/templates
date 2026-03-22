#!/bin/bash
# ClawRain Agent Setup Script v2
# Usage: ./setup.sh --config config.json
# Or:    curl -fsSL https://raw.githubusercontent.com/clawrainai/templates/main/setup.sh | bash -s -- --config config.json

set -e

REGISTRY="https://github.com/clawrainai/agents"
TEMPLATES_REPO="https://github.com/clawrainai/templates"
AGENTS_REPO="https://github.com/clawrainai/agents"

usage() {
  echo "Usage: $0 --config config.json [--workspace WORKSPACE_DIR]"
  echo ""
  echo "Options:"
  echo "  --config PATH          Path to config.json from ClawRain (required)"
  echo "  --workspace DIR        Workspace directory (default: ~/.openclaw/workspace-{agentId})"
  echo "  --help                 Show this help"
  exit 1
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse args
CONFIG_PATH=""
WORKSPACE_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --workspace)
      WORKSPACE_DIR="$2"
      shift 2
      ;;
    --help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

# Validate config
if [[ -z "$CONFIG_PATH" ]]; then
  log_error "--config is required"
  usage
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  log_error "Config file not found: $CONFIG_PATH"
  exit 1
fi

# Validate jq is available
if ! command -v jq &> /dev/null; then
  log_info "Installing jq..."
  sudo apt-get update && sudo apt-get install -y jq
fi

# Parse config
AGENT_ID=$(jq -r '.agent_id // .agentId' "$CONFIG_PATH" 2>/dev/null || jq -r '.agentId' "$CONFIG_PATH")
MARKET=$(jq -r '.market' "$CONFIG_PATH")
SERVICE=$(jq -r '.service // "senpi"' "$CONFIG_PATH")
STRATEGY=$(jq -r '.strategy' "$CONFIG_PATH")
IDENTITY_ADDRESS=$(jq -r '.identity.address // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform.api_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform.endpoint // empty' "$CONFIG_PATH")
STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '.' '-')

echo ""
log_info "ClawRain Agent Setup v2"
echo "========================="
echo "  Agent ID:   $AGENT_ID"
echo "  Market:     $MARKET"
echo "  Service:    $SERVICE"
echo "  Strategy:   $STRATEGY"
echo ""

# Set workspace dir
if [[ -z "$WORKSPACE_DIR" ]]; then
  WORKSPACE_DIR="$HOME/.openclaw/workspace-$AGENT_ID"
fi

log_info "Workspace: $WORKSPACE_DIR"
echo ""

# Check if already exists
if [[ -d "$WORKSPACE_DIR" ]]; then
  log_warn "Workspace already exists."
  read -p "Overwrite? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_error "Aborted."
    exit 1
  fi
  rm -rf "$WORKSPACE_DIR"
fi

# Create workspace
log_info "Creating workspace..."
mkdir -p "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR/memory"
mkdir -p "$HOME/.config/senpi"

# =============================================
# STEP 1: Clone registry and copy strategy
# =============================================
log_info "Fetching strategy from registry..."
git clone --depth 1 "$REGISTRY" "$WORKSPACE_DIR/registry" 2>/dev/null || {
  log_error "Failed to clone registry"
  exit 1
}

STRATEGY_DIR="$WORKSPACE_DIR/registry/$MARKET/$SERVICE/$STRATEGY_KEBAB"
if [[ ! -d "$STRATEGY_DIR" ]]; then
  log_error "Strategy not found: $MARKET/$SERVICE/$STRATEGY"
  exit 1
fi

# Copy strategy config (merge with user params)
cp "$STRATEGY_DIR/config.json" "$WORKSPACE_DIR/strategy.json"

# Copy skills
if [[ -d "$STRATEGY_DIR/skills" ]]; then
  mkdir -p "$WORKSPACE_DIR/skills"
  cp -r "$STRATEGY_DIR/skills/"* "$WORKSPACE_DIR/skills/" 2>/dev/null || true
fi

# Copy memory template
MEMORY_TEMPLATE="$STRATEGY_DIR/memory/template.md"
if [[ -f "$MEMORY_TEMPLATE" ]]; then
  TODAY=$(date +%Y-%m-%d)
  cp "$MEMORY_TEMPLATE" "$WORKSPACE_DIR/memory/$TODAY.md"
fi

# Cleanup registry
rm -rf "$WORKSPACE_DIR/registry"

# =============================================
# STEP 2: Copy user config
# =============================================
log_info "Installing config..."
cp "$CONFIG_PATH" "$WORKSPACE_DIR/config.json"

# =============================================
# STEP 3: Install & configure Senpi
# =============================================
if [[ "$SERVICE" == "senpi" ]]; then
  log_info "Setting up Senpi..."

  # Check if npx is available
  if ! command -v npx &> /dev/null; then
    log_error "npx is required. Install Node.js first."
    exit 1
  fi

  # Generate agent wallet using identity address
  if [[ -n "$IDENTITY_ADDRESS" ]]; then
    log_info "Generating agent wallet with identity: $IDENTITY_ADDRESS"
    
    # Run senpi onboard (this generates wallet on VPS)
    cd "$WORKSPACE_DIR"
    npx onboard-senpi --wallet "$IDENTITY_ADDRESS" 2>/dev/null || {
      log_warn "onboard-senpi not available yet - will be run on first boot"
    }
  else
    log_warn "No identity wallet provided. Agent wallet will be generated on first boot."
  fi
fi

# =============================================
# STEP 4: Install Cloudflare Tunnel
# =============================================
log_info "Setting up Cloudflare Tunnel..."

if ! command -v cloudflared &> /dev/null; then
  log_info "Installing cloudflared..."
  
  # Detect architecture
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  elif [[ "$ARCH" == "arm64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  else
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  fi
  
  curl -L "$CLOUDFLARED_URL" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

# Create tunnel
TUNNEL_NAME="agent-$AGENT_ID"
log_info "Creating tunnel: $TUNNEL_NAME..."

# Check if tunnel already exists
EXISTING_TOKEN=$(cat "$HOME/.config/clawrain/tunnel_token" 2>/dev/null || echo "")

if [[ -z "$EXISTING_TOKEN" ]]; then
  # Create new tunnel (non-interactive)
  cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
fi

# Route DNS
log_info "Routing DNS..."
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || {
  log_warn "DNS routing failed - will use trycloudflare.com instead"
}

# Save tunnel token for auto-restart
mkdir -p "$HOME/.config/clawrain"
echo "$TUNNEL_NAME" > "$HOME/.config/clawrain/tunnel_name"

log_info "Cloudflare Tunnel ready!"

# =============================================
# STEP 5: Create base files
# =============================================
log_info "Creating agent files..."

cat > "$WORKSPACE_DIR/identity.md" << EOF
# Identity

## Agent
- Name: $AGENT_ID
- Role: Trading agent for $MARKET
- Market: $MARKET
- Strategy: $STRATEGY

## Identity Wallet
- Address: $IDENTITY_ADDRESS
- Chain: $MARKET

## Agent Wallet
- Generated by Senpi on first boot
- Stored in: ~/.config/senpi/wallet.json
EOF

cat > "$WORKSPACE_DIR/soul.md" << 'EOF'
# Soul

## Vibe
A focused, efficient trading agent. No fluff, just results.

## Principles
- Protect the user's funds at all costs
- Be transparent about trades and performance
- Never expose private keys or credentials
- Push metrics in real-time to the dashboard

## Behavior
- Always confirm large trades
- Log everything to SQLite for historical analysis
- Notify via Telegram when configured
EOF

cat > "$WORKSPACE_DIR/AGENTS.md" << 'EOF'
# AGENTS.md

## Mission
You are a ClawRain trading agent running on OpenClaw.

## Your Setup
- Market: FILL FROM CONFIG
- Strategy: FILL FROM CONFIG  
- Service: FILL FROM CONFIG

## Workflow
1. Boot: openclaw agent
2. First boot: Senpi generates agent wallet
3. Fund agent wallet with USDC
4. Trading begins automatically
5. Push metrics to GenosDB every 30s
6. Cloudflare Tunnel exposes metrics API

## Memory
Write daily notes in memory/YYYY-MM-DD.md

## Skills
Your skills are in: skills/

## Security
- NEVER expose wallet private keys
- NEVER log sensitive credentials
- All secrets stay on this VPS only
EOF

cat > "$WORKSPACE_DIR/start-agent.sh" << EOF
#!/bin/bash
# Start the ClawRain agent

WORKSPACE_DIR="$WORKSPACE_DIR"
TUNNEL_NAME="$TUNNEL_NAME"

echo "Starting ClawRain Agent: $AGENT_ID"
echo ""

# Start cloudflare tunnel in background
if command -v cloudflared &> /dev/null; then
  echo "Starting Cloudflare Tunnel..."
  cloudflared tunnel run --token "\$(cat $HOME/.config/clawrain/tunnel_token 2>/dev/null)" "$TUNNEL_NAME" &> /tmp/clawrain-tunnel.log &
fi

# Start OpenClaw agent
cd "\$WORKSPACE_DIR"
exec openclaw agent
EOF

chmod +x "$WORKSPACE_DIR/start-agent.sh"

# Make config immutable
chmod 444 "$WORKSPACE_DIR/config.json"
chmod 444 "$WORKSPACE_DIR/strategy.json"

# =============================================
# STEP 6: Register with Supabase (optional)
# =============================================
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_info "Registering agent with platform..."
  
  # Send initial status
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_status" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"status\":\"provisioned\"}" 2>/dev/null || {
    log_warn "Could not register with platform (will retry on first boot)"
  }
fi

# =============================================
# DONE
# =============================================
echo ""
log_info "✅ Setup complete!"
echo ""
echo "Files created:"
ls -la "$WORKSPACE_DIR"
echo ""
echo "Next steps:"
echo "1. Fund agent wallet: openclaw agent --workspace $WORKSPACE_DIR"
echo "2. On first boot, Senpi will generate the agent wallet"
echo "3. Transfer USDC to the agent wallet address shown"
echo "4. Agent will start trading automatically"
echo ""
echo "To start the agent:"
echo "  $WORKSPACE_DIR/start-agent.sh"
echo ""
echo "Agent endpoint (via tunnel): https://$TUNNEL_NAME.trycloudflare.com"
echo ""
