#!/bin/bash
# ClawRain Agent Setup Script v4
# Usage: ./setup.sh --config config.json
# Or:    curl -fsSL https://raw.githubusercontent.com/clawrainai/templates/main/setup.sh | bash -s -- --config config.json

set -e

# ─── Repos ─────────────────────────────────────────────────────────────────
SENPI_UPSTREAM="https://github.com/Senpi-ai/senpi-skills"
TEMPLATES_REPO="https://github.com/clawrainai/templates"

# ─── Usage ─────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 --config config.json [--workspace DIR]"
  echo "  --config PATH    config.json from ClawRain (required)"
  echo "  --workspace DIR  workspace dir (default: ~/.openclaw/workspace-{agentId})"
  exit 1
}

# ─── Helpers ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Args ──────────────────────────────────────────────────────────────────
CONFIG_PATH=""
WORKSPACE_DIR=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --config)    CONFIG_PATH="$2"; shift 2 ;;
    --workspace)  WORKSPACE_DIR="$2"; shift 2 ;;
    --help)       usage ;;
    *)            log_error "Unknown: $1"; usage ;;
  esac
done

[[ -z "$CONFIG_PATH" ]] && { log_error "--config required"; usage; }
[[ ! -f "$CONFIG_PATH" ]] && { log_error "Config not found: $CONFIG_PATH"; exit 1; }

# ─── Validate deps ──────────────────────────────────────────────────────────
command -v jq   &>/dev/null || { log_info "Installing jq..."; sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
command -v git  &>/dev/null || { log_error "git required"; exit 1; }
command -v npx  &>/dev/null || { log_error "npx (Node.js) required"; exit 1; }

# ─── Parse config ──────────────────────────────────────────────────────────
AGENT_ID=$(jq -r '.agent_id // .agentId // empty' "$CONFIG_PATH")
MARKET=$(jq -r '.market // empty' "$CONFIG_PATH")
SERVICE=$(jq -r '.service // "senpi"' "$CONFIG_PATH")
STRATEGY=$(jq -r '.strategy // empty' "$CONFIG_PATH")
IDENTITY_ADDRESS=$(jq -r '.identity.address // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform.api_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform.endpoint // empty' "$CONFIG_PATH")

[[ -z "$AGENT_ID"  ]] && { log_error "agent_id missing in config"; exit 1; }
[[ -z "$MARKET"   ]] && { log_error "market missing in config"; exit 1; }
[[ -z "$STRATEGY" ]] && { log_error "strategy missing in config"; exit 1; }

STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '.' '-')

# ─── Workspace ─────────────────────────────────────────────────────────────
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace-$AGENT_ID}"

log_info "ClawRain Agent Setup v4"
echo "========================================"
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

# ─── STEP 1: Install config ─────────────────────────────────────────────────
log_info "Installing config..."
cp "$CONFIG_PATH" "$WORKSPACE_DIR/setup-config.json"
chmod 444 "$WORKSPACE_DIR/setup-config.json"

# ─── STEP 2: Onboard Senpi FIRST — generates wallet + crons ─────────────────
if [[ "$SERVICE" == "senpi" ]]; then
  log_info "Running Senpi onboarding..."
  log_info "This will generate the agent wallet and configure trading crons."
  echo ""

  if npx --yes senpi-onboard --config "$WORKSPACE_DIR/config.json" 2>&1; then
    log_info "Senpi onboarding complete!"
  else
    log_warn "Senpi onboarding failed — will retry on first boot"
  fi
fi

# ─── STEP 3: Clone Senpi strategy ───────────────────────────────────────────
log_info "Fetching strategy from Senpi upstream..."
git clone --depth 1 "$SENPI_UPSTREAM" "$WORKSPACE_DIR/senpi-registry" 2>/dev/null || {
  log_error "Failed to clone Senpi upstream"
  exit 1
}

STRATEGY_DIR="$WORKSPACE_DIR/senpi-registry/$MARKET/$SERVICE/$STRATEGY_KEBAB"
if [[ ! -d "$STRATEGY_DIR" ]]; then
  log_error "Strategy not found: $MARKET/$SERVICE/$STRATEGY"
  exit 1
fi

cp "$STRATEGY_DIR/config.json" "$WORKSPACE_DIR/strategy.json"
cp -r "$STRATEGY_DIR/skills/"* "$WORKSPACE_DIR/skills/" 2>/dev/null || true

MEMORY_TPL="$STRATEGY_DIR/memory/template.md"
[[ -f "$MEMORY_TPL" ]] && cp "$MEMORY_TPL" "$WORKSPACE_DIR/memory/$(date +%Y-%m-%d).md"

rm -rf "$WORKSPACE_DIR/senpi-registry"

# ─── STEP 4: Inject clawrain-agent (metrics server) ────────────────────────────
log_info "Injecting ClawRain infrastructure..."

git clone --depth 1 --filter=blob:none --sparse "$TEMPLATES_REPO" \
  "$WORKSPACE_DIR/templates" 2>/dev/null

if git -C "$WORKSPACE_DIR/templates" sparse-checkout set base 2>/dev/null; then
  : # ok
else
  git -C "$WORKSPACE_DIR/templates" sparse-checkout init 2>/dev/null
  git -C "$WORKSPACE_DIR/templates" sparse-checkout set base 2>/dev/null
fi

if [[ -d "$WORKSPACE_DIR/templates/base/clawrain-agent" ]]; then
  mkdir -p "$WORKSPACE_DIR/clawrain-agent"
  cp -r "$WORKSPACE_DIR/templates/base/clawrain-agent/"* "$WORKSPACE_DIR/clawrain-agent/"
  log_info "clawrain-agent installed"
fi

# Copy base OpenClaw files
for f in identity.md soul.md AGENTS.md; do
  [[ -f "$WORKSPACE_DIR/templates/base/$f" ]] && cp "$WORKSPACE_DIR/templates/base/$f" "$WORKSPACE_DIR/"
done

rm -rf "$WORKSPACE_DIR/templates"

# ─── STEP 5: Cloudflare Tunnel ───────────────────────────────────────────────
log_info "Setting up Cloudflare Tunnel..."

if ! command -v cloudflared &>/dev/null; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64)   URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *)       URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  esac
  curl -L "$URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi

TUNNEL_NAME="agent-$AGENT_ID"
cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || true
echo "$TUNNEL_NAME" > "$HOME/.config/clawrain/tunnel_name"

log_info "Tunnel ready: https://$TUNNEL_NAME.trycloudflare.com"

# ─── STEP 6: Register with Supabase ───────────────────────────────────────
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_info "Registering agent with platform..."
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_metrics" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"status\":\"provisioned\",\"equity\":0,\"pnl_total\":0}" \
    || log_warn "Could not register with platform"
fi

# ─── STEP 7: Install + start clawrain-agent ───────────────────────────────
if [[ -f "$WORKSPACE_DIR/clawrain-agent/clawrain_agent-0.1.0.tar.gz" ]]; then
  log_info "Installing clawrain-agent..."

  # Install Python dependencies
  pip install fastapi uvicorn[standard] python-multipart aiofiles httpx \
    --quiet 2>/dev/null || true

  # Install clawrain-agent from local tarball
  pip install "$WORKSPACE_DIR/clawrain-agent/clawrain_agent-0.1.0.tar.gz" \
    --quiet 2>/dev/null || {
    log_warn "clawrain-agent install failed — trying from PyPI"
    pip install clawrain-agent --quiet 2>/dev/null || true
  }

  if command -v clawrain-agent &>/dev/null; then
    log_info "Starting clawrain-agent on port 8000..."
    clawrain-agent init --config "$WORKSPACE_DIR/setup-config.json" 2>/dev/null || true
    nohup clawrain-agent start --config "$WORKSPACE_DIR/setup-config.json" --port 8000 \
      >> /tmp/clawrain-agent-$AGENT_ID.log 2>&1 &
    echo $! > "$HOME/.config/clawrain/agent.pid"
    log_info "clawrain-agent running (PID $(cat $HOME/.config/clawrain/agent.pid))"
    log_info "Metrics API: http://localhost:8000"
  else
    log_warn "clawrain-agent not available — metrics will not be served"
  fi
fi

# ─── STEP 8: Create start script ───────────────────────────────────────────
cat > "$WORKSPACE_DIR/start.sh" << 'START'
#!/bin/bash
AGENT_DIR="$(dirname "$0")"
SCRIPT
echo "AGENT_ID=\"$AGENT_ID\"" >> "$WORKSPACE_DIR/start.sh"

cat >> "$WORKSPACE_DIR/start.sh" << 'START'
TUNNEL_NAME="$(cat $HOME/.config/clawrain/tunnel_name 2>/dev/null || echo "agent-$AGENT_ID")"

# Cloudflare Tunnel
if command -v cloudflared &>/dev/null; then
  cloudflared tunnel run "$TUNNEL_NAME" &>/tmp/clawrain-tunnel-$AGENT_ID.log &
fi

# platform-push
if [[ -f "$AGENT_DIR/skills/platform-push/platform-push.js" ]]; then
  nohup node "$AGENT_DIR/skills/platform-push/platform-push.js" \
    >> /tmp/clawrain-push-$AGENT_ID.log 2>&1 &
fi

# OpenClaw agent
cd "$AGENT_DIR"
exec openclaw agent
START

chmod +x "$WORKSPACE_DIR/start.sh"

# ─── DONE ───────────────────────────────────────────────────────────────────
echo ""
log_info "✅ Setup complete!"
echo ""
echo "Files:"
ls -la "$WORKSPACE_DIR"
echo ""
echo "Logs:"
echo "  platform-push: tail -f /tmp/clawrain-push-$AGENT_ID.log"
echo "  tunnel:       tail -f /tmp/clawrain-tunnel-$AGENT_ID.log"
echo ""
echo "To start: $WORKSPACE_DIR/start.sh"
echo ""
