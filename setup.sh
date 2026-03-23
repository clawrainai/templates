#!/bin/bash
# ClawRain Agent Setup Script v3
# Usage: ./setup.sh --config config.json
# Or:    curl -fsSL https://raw.githubusercontent.com/clawrainai/templates/main/setup.sh | bash -s -- --config config.json

set -e

# ─── Repositories ───────────────────────────────────────────────────────────
SENPI_UPSTREAM="https://github.com/Senpi-ai/senpi-skills"
TEMPLATES_REPO="https://github.com/clawrainai/templates"

usage() {
  echo "Usage: $0 --config config.json [--workspace WORKSPACE_DIR]"
  echo ""
  echo "Options:"
  echo "  --config PATH          Path to config.json from ClawRain (required)"
  echo "  --workspace DIR        Workspace directory (default: ~/.openclaw/workspace-{agentId})"
  echo "  --help                 Show this help"
  exit 1
}

# ─── Helpers ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Parse args ─────────────────────────────────────────────────────────────
CONFIG_PATH=""
WORKSPACE_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)    CONFIG_PATH="$2"; shift 2 ;;
    --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
    --help)      usage ;;
    *)           log_error "Unknown: $1"; usage ;;
  esac
done

[[ -z "$CONFIG_PATH" ]] && { log_error "--config required"; usage; }
[[ ! -f "$CONFIG_PATH" ]] && { log_error "Config not found: $CONFIG_PATH"; exit 1; }

# ─── Validate tools ─────────────────────────────────────────────────────────
command -v jq &>/dev/null || { log_info "Installing jq..."; sudo apt-get update && sudo apt-get install -y jq; }

# ─── Parse config ───────────────────────────────────────────────────────────
AGENT_ID=$(jq -r '.agent_id // .agentId // empty' "$CONFIG_PATH")
MARKET=$(jq -r '.market // empty' "$CONFIG_PATH")
SERVICE=$(jq -r '.service // "senpi"' "$CONFIG_PATH")
STRATEGY=$(jq -r '.strategy // empty' "$CONFIG_PATH")
IDENTITY_ADDRESS=$(jq -r '.identity.address // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform.api_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform.endpoint // empty' "$CONFIG_PATH")

[[ -z "$AGENT_ID" ]]  && { log_error "agent_id missing in config"; exit 1; }
[[ -z "$MARKET" ]]   && { log_error "market missing in config"; exit 1; }
[[ -z "$STRATEGY" ]] && { log_error "strategy missing in config"; exit 1; }

STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '.' '-')

# ─── Workspace ───────────────────────────────────────────────────────────────
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace-$AGENT_ID}"

log_info "ClawRain Agent Setup v3"
echo "========================="
echo "  Agent ID:   $AGENT_ID"
echo "  Market:     $MARKET"
echo "  Strategy:   $STRATEGY"
echo "  Workspace:  $WORKSPACE_DIR"
echo ""

if [[ -d "$WORKSPACE_DIR" ]]; then
  log_warn "Workspace exists. Overwrite? [y/N]"
  read -r REPLY
  [[ ! "$REPLY" =~ ^[Yy]$ ]] && { log_error "Aborted."; exit 1; }
  rm -rf "$WORKSPACE_DIR"
fi

mkdir -p "$WORKSPACE_DIR"/{skills,memory}
mkdir -p "$HOME/.config/senpi"
mkdir -p "$HOME/.config/clawrain"

# ─── STEP 1: Clone Senpi upstream ──────────────────────────────────────────
log_info "Fetching strategy from Senpi..."
git clone --depth 1 "$SENPI_UPSTREAM" "$WORKSPACE_DIR/senpi-registry" 2>/dev/null || {
  log_error "Failed to clone Senpi upstream"
  exit 1
}

STRATEGY_DIR="$WORKSPACE_DIR/senpi-registry/$MARKET/$SERVICE/$STRATEGY_KEBAB"
if [[ ! -d "$STRATEGY_DIR" ]]; then
  log_error "Strategy not found: $MARKET/$SERVICE/$STRATEGY"
  exit 1
fi

# Copy strategy
cp "$STRATEGY_DIR/config.json" "$WORKSPACE_DIR/strategy.json"
cp -r "$STRATEGY_DIR/skills/"* "$WORKSPACE_DIR/skills/" 2>/dev/null || true

# Memory template
MEMORY_TPL="$STRATEGY_DIR/memory/template.md"
[[ -f "$MEMORY_TPL" ]] && cp "$MEMORY_TPL" "$WORKSPACE_DIR/memory/$(date +%Y-%m-%d).md"

rm -rf "$WORKSPACE_DIR/senpi-registry"

# ─── STEP 2: Inject ClawRain infrastructure ────────────────────────────────
log_info "Injecting ClawRain infrastructure..."

# Clone templates (shallow, just for base/)
git clone --depth 1 --filter=blob:none --sparse "$TEMPLATES_REPO" "$WORKSPACE_DIR/templates" 2>/dev/null
git -C "$WORKSPACE_DIR/templates" sparse-checkout set base/skills 2>/dev/null || {
  # Fallback: full clone if sparse fails
  git -C "$WORKSPACE_DIR/templates" sparse-checkout init 2>/dev/null
  git -C "$WORKSPACE_DIR/templates" sparse-checkout set base/skills 2>/dev/null
}

# Copy platform-push (metrics → Supabase)
if [[ -d "$WORKSPACE_DIR/templates/base/skills/platform-push" ]]; then
  cp -r "$WORKSPACE_DIR/templates/base/skills/platform-push" "$WORKSPACE_DIR/skills/"
  log_info "platform-push installed"
fi

# Copy base OpenClaw files
for f in identity.md soul.md AGENTS.md; do
  [[ -f "$WORKSPACE_DIR/templates/base/$f" ]] && cp "$WORKSPACE_DIR/templates/base/$f" "$WORKSPACE_DIR/"
done

rm -rf "$WORKSPACE_DIR/templates"

# ─── STEP 3: Install config ──────────────────────────────────────────────────
log_info "Installing config..."
cp "$CONFIG_PATH" "$WORKSPACE_DIR/config.json"
chmod 444 "$WORKSPACE_DIR/config.json"

# ─── STEP 4: Setup Cloudflare Tunnel ────────────────────────────────────────
log_info "Setting up Cloudflare Tunnel..."

if ! command -v cloudflared &>/dev/null; then
  ARCH=$(uname -m)
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH#x}.amd64"
  curl -L "$URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi

TUNNEL_NAME="agent-$AGENT_ID"
cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || true
echo "$TUNNEL_NAME" > "$HOME/.config/clawrain/tunnel_name"

log_info "Tunnel ready: https://$TUNNEL_NAME.trycloudflare.com"

# ─── STEP 5: Setup Senpi ─────────────────────────────────────────────────────
if [[ "$SERVICE" == "senpi" ]]; then
  log_info "Setting up Senpi..."

  command -v npx &>/dev/null || { log_error "npx required (Node.js)"; exit 1; }

  if [[ -n "$IDENTITY_ADDRESS" ]]; then
    log_info "Identity wallet: $IDENTITY_ADDRESS"
  fi

  # senpi-onboard generates wallet, crons, MCP config
  npx --yes senpi-onboard --config "$WORKSPACE_DIR/config.json" 2>/dev/null || {
    log_warn "senpi-onboard skipped — run manually on first boot"
  }
fi

# ─── STEP 6: Register with Supabase ────────────────────────────────────────
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_info "Registering agent..."
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_metrics" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"status\":\"provisioned\",\"equity\":0,\"pnl_total\":0}" \
    || log_warn "Could not register (will retry on boot)"
fi

# ─── STEP 7: Start platform-push in background ────────────────────────────────
if [[ -f "$WORKSPACE_DIR/skills/platform-push/platform-push.js" ]]; then
  log_info "Starting platform-push..."
  # Run in background, log to file
  nohup node "$WORKSPACE_DIR/skills/platform-push/platform-push.js" \
    >> /tmp/clawrain-push-$AGENT_ID.log 2>&1 &
  echo $! > "$HOME/.config/clawrain/platform-push.pid"
  log_info "platform-push PID: $(cat $HOME/.config/clawrain/platform-push.pid)"
fi

# ─── Create start script ─────────────────────────────────────────────────────
cat > "$WORKSPACE_DIR/start.sh" << 'SCRIPT'
#!/bin/bash
AGENT_ID="PLACEHOLDER"
SCRIPT
sed -i "s/AGENT_ID=\"PLACEHOLDER\"/AGENT_ID=\"$AGENT_ID\"/" "$WORKSPACE_DIR/start.sh"

cat >> "$WORKSPACE_DIR/start.sh" << 'SCRIPT'
WORKSPACE_DIR="$(dirname "$0")"
TUNNEL_NAME="$(cat $HOME/.config/clawrain/tunnel_name 2>/dev/null || echo "agent-$AGENT_ID")"

echo "Starting ClawRain Agent: $AGENT_ID"

# Cloudflare Tunnel
if command -v cloudflared &>/dev/null; then
  cloudflared tunnel run --token "$(cat $HOME/.config/clawrain/tunnel_token 2>/dev/null)" \
    "$TUNNEL_NAME" &>/tmp/clawrain-tunnel-$AGENT_ID.log &
fi

# platform-push
if [[ -f "$WORKSPACE_DIR/skills/platform-push/platform-push.js" ]]; then
  nohup node "$WORKSPACE_DIR/skills/platform-push/platform-push.js" \
    >> /tmp/clawrain-push-$AGENT_ID.log 2>&1 &
fi

# OpenClaw agent
cd "$WORKSPACE_DIR"
exec openclaw agent
SCRIPT

chmod +x "$WORKSPACE_DIR/start.sh"

# ─── DONE ───────────────────────────────────────────────────────────────────
echo ""
log_info "✅ Setup complete!"
echo ""
ls "$WORKSPACE_DIR"
echo ""
echo "Next steps:"
echo "1. Fund agent wallet (address shown by Senpi on first boot)"
echo "2. Start: $WORKSPACE_DIR/start.sh"
echo "3. Monitor: tail -f /tmp/clawrain-push-$AGENT_ID.log"
echo ""
