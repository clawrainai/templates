#!/bin/bash
# ClawRain Agent Setup Script v5
# Usage:
#   curl ...setup.sh | bash -s -- --agent-id ID    # from ClawRain Hub API
#   curl ...setup.sh | bash -s -- --config FILE   # from downloaded config.json

set -e

# ─── Repos ─────────────────────────────────────────────────────────────────
SENPI_UPSTREAM="https://github.com/Senpi-ai/senpi-skills"
TEMPLATES_REPO="https://github.com/clawrainai/templates"

# ─── Helpers ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  echo "Usage:"
  echo "  curl ...setup.sh | bash -s -- --agent-id ID    # from ClawRain Hub API"
  echo "  curl ...setup.sh | bash -s -- --config FILE   # from downloaded config.json"
  exit 1
}

# ─── Args ──────────────────────────────────────────────────────────────────
AGENT_ID=""
CONFIG_PATH=""
WORKSPACE_DIR=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-id)   AGENT_ID="$2"; shift 2 ;;
    --config)     CONFIG_PATH="$2"; shift 2 ;;
    --workspace)  WORKSPACE_DIR="$2"; shift 2 ;;
    --help)       usage ;;
    *)            log_error "Unknown: $1"; usage ;;
  esac
done

# ─── Config ─────────────────────────────────────────────────────────────────
# Mode 1: AGENT_ID only (from ClawRain Hub API — config embedded)
if [[ -n "$AGENT_ID" && -z "$CONFIG_PATH" ]]; then
  if [[ -z "$CLAWRAIN_CONFIG" ]]; then
    log_error "No config provided. Use --config or run via the Hub setup URL."
    usage
  fi
  CONFIG_PATH="/tmp/agent-config-$AGENT_ID.json"
  echo "$CLAWRAIN_CONFIG" | base64 -d > "$CONFIG_PATH"
  log_info "Config loaded from embedded data"

# Mode 2: Local config file
elif [[ -n "$CONFIG_PATH" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    log_error "Config not found: $CONFIG_PATH"
    usage
  fi
  log_info "Config loaded: $CONFIG_PATH"
  [[ -z "$AGENT_ID" ]] && AGENT_ID=$(jq -r '.agent_id // .agentId // empty' "$CONFIG_PATH")
else
  log_error "--agent-id or --config required"
  usage
fi

# ─── Validate deps ──────────────────────────────────────────────────────────
command -v jq   &>/dev/null || { log_info "Installing jq..."; sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
command -v git  &>/dev/null || { log_error "git required"; exit 1; }
command -v node &>/dev/null || { log_error "node (Node.js) required"; exit 1; }

# ─── Parse config ──────────────────────────────────────────────────────────
[[ -z "$AGENT_ID" ]] && AGENT_ID=$(jq -r '.agent_id // .agentId // empty' "$CONFIG_PATH")
[[ -z "$AGENT_ID" ]] && { log_error "agent_id missing in config"; exit 1; }

MARKET=$(jq -r '.market // empty' "$CONFIG_PATH")
SERVICE=$(jq -r '.service // "senpi"' "$CONFIG_PATH")
STRATEGY=$(jq -r '.strategy // empty' "$CONFIG_PATH")
IDENTITY_ADDRESS=$(jq -r '.identity.address // empty' "$CONFIG_PATH")
SKILL_REPO=$(jq -r '.skill.repo // "https://github.com/Senpi-ai/senpi-skills"' "$CONFIG_PATH")
SKILL_PATH=$(jq -r '.skill.path // empty' "$CONFIG_PATH")
SKILL_BRANCH=$(jq -r '.skill.branch // "main"' "$CONFIG_PATH")
PLATFORM_URL=$(jq -r '.platform_url // empty' "$CONFIG_PATH")
PLATFORM_TOKEN=$(jq -r '.platform_token // empty' "$CONFIG_PATH")
PLATFORM_ENDPOINT=$(jq -r '.platform_endpoint // empty' "$CONFIG_PATH")

[[ -z "$MARKET" ]]    && { log_error "market missing in config"; exit 1; }
[[ -z "$STRATEGY" ]]  && { log_error "strategy missing in config"; exit 1; }
[[ -z "$SKILL_PATH" ]] && { log_error "skill.path missing in config"; exit 1; }

# ─── Workspace ─────────────────────────────────────────────────────────────
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace-$AGENT_ID}"

log_info "ClawRain Agent Setup v5"
echo "========================================"
echo "  Agent ID:   $AGENT_ID"
echo "  Market:     $MARKET"
echo "  Strategy:   $STRATEGY"
echo "  Skill path: $SKILL_PATH"
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

# ─── STEP 2: Clone senpi-skills (full repo for skills + onboard) ───────────
SENPI_TMP="/tmp/senpi-skills-$AGENT_ID"
log_info "Cloning Senpi skills repo..."
git clone --depth 1 "$SENPI_UPSTREAM" "$SENPI_TMP" 2>/dev/null || {
  log_error "Failed to clone $SENPI_UPSTREAM"
  exit 1
}

# ─── STEP 3: Run senpi-onboard if service == senpi ──────────────────────────
if [[ "$SERVICE" == "senpi" ]]; then
  log_info "Running Senpi onboarding (wallet generation)..."

  ONBOARD_SCRIPT="$SENPI_TMP/senpi-onboard/scripts/generate_wallet.js"
  if [[ -f "$ONBOARD_SCRIPT" ]]; then
    if node "$ONBOARD_SCRIPT" --config "$WORKSPACE_DIR/setup-config.json" 2>&1; then
      log_info "Senpi onboarding complete!"
    else
      log_warn "Senpi onboarding failed — will retry on first boot"
    fi
  else
    log_warn "senpi-onboard script not found at $ONBOARD_SCRIPT"
  fi
fi

# ─── STEP 4: Copy strategy skill ────────────────────────────────────────────
log_info "Fetching strategy '$STRATEGY' from Senpi upstream..."

STRATEGY_DIR="$SENPI_TMP/$SKILL_PATH"
if [[ ! -d "$STRATEGY_DIR" ]]; then
  log_error "Strategy not found at '$SKILL_PATH' in Senpi repo"
  log_error "Available top-level items:"
  ls "$SENPI_TMP" | grep -v "^\." | head -20
  rm -rf "$SENPI_TMP"
  exit 1
fi

cp "$STRATEGY_DIR/config.json" "$WORKSPACE_DIR/strategy.json" 2>/dev/null || {
  log_warn "No config.json found in strategy"
}

# Copy skills from strategy
if [[ -d "$STRATEGY_DIR/skills" ]]; then
  cp -r "$STRATEGY_DIR/skills/"* "$WORKSPACE_DIR/skills/" 2>/dev/null || true
fi

# Copy memory template if exists
MEMORY_TPL="$STRATEGY_DIR/memory/template.md"
[[ -f "$MEMORY_TPL" ]] && cp "$MEMORY_TPL" "$WORKSPACE_DIR/memory/$(date +%Y-%m-%d).md"

rm -rf "$SENPI_TMP"

# ─── STEP 5: Inject clawrain-agent (metrics server) ─────────────────────────
log_info "Injecting ClawRain infrastructure..."

CLAWRAIN_TMP="/tmp/clawrain-templates-$AGENT_ID"
git clone --depth 1 "$TEMPLATES_REPO" "$CLAWRAIN_TMP" 2>/dev/null || {
  log_warn "Could not clone templates repo"
}

if [[ -d "$CLAWRAIN_TMP/base/clawrain-agent" ]]; then
  mkdir -p "$WORKSPACE_DIR/clawrain-agent"
  cp -r "$CLAWRAIN_TMP/base/clawrain-agent/"* "$WORKSPACE_DIR/clawrain-agent/"
  log_info "clawrain-agent installed"
fi

# Copy base OpenClaw files
for f in identity.md soul.md AGENTS.md; do
  [[ -f "$CLAWRAIN_TMP/base/$f" ]] && cp "$CLAWRAIN_TMP/base/$f" "$WORKSPACE_DIR/"
done

rm -rf "$CLAWRAIN_TMP"

# ─── STEP 6: Cloudflare Tunnel ───────────────────────────────────────────────
log_info "Setting up Cloudflare Tunnel..."

if ! command -v cloudflared &>/dev/null; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64|aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *)       URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  esac
  curl -L "$URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi

TUNNEL_NAME="agent-$AGENT_ID"
cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || true
echo "$TUNNEL_NAME" > "$HOME/.config/clawrain/tunnel_name"

log_info "Tunnel ready: https://$TUNNEL_NAME.trycloudflare.com"

# ─── STEP 7: Register with platform ─────────────────────────────────────────
if [[ -n "$PLATFORM_TOKEN" && -n "$PLATFORM_ENDPOINT" ]]; then
  log_info "Registering agent with platform..."
  curl -s -X POST "$PLATFORM_ENDPOINT/rest/v1/agent_metrics" \
    -H "Authorization: Bearer $PLATFORM_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"agent_id\":\"$AGENT_ID\",\"status\":\"provisioned\",\"equity\":0,\"pnl_total\":0}" \
    || log_warn "Could not register with platform"
fi

# ─── STEP 8: Install clawrain-agent ─────────────────────────────────────────
if [[ -f "$WORKSPACE_DIR/clawrain-agent/clawrain_agent-0.1.0.tar.gz" ]]; then
  log_info "Installing clawrain-agent..."

  pip install fastapi uvicorn[standard] python-multipart aiofiles httpx \
    --quiet 2>/dev/null || true

  pip install "$WORKSPACE_DIR/clawrain-agent/clawrain_agent-0.1.0.tar.gz" \
    --quiet 2>/dev/null || {
    log_warn "clawrain-agent tarball install failed — trying PyPI"
    pip install clawrain-agent --quiet 2>/dev/null || true
  }

  if command -v clawrain-agent &>/dev/null; then
    log_info "clawrain-agent binary available"
  else
    log_warn "clawrain-agent not in PATH — skipping metrics server"
  fi
fi

# ─── STEP 9: Create start script ───────────────────────────────────────────
cat > "$WORKSPACE_DIR/start.sh" << 'STARTSCRIPT'
#!/bin/bash
AGENT_DIR="$(dirname "$0")"
AGENT_ID="$(basename "$AGENT_DIR")"
TUNNEL_NAME="$(cat $HOME/.config/clawrain/tunnel_name 2>/dev/null || echo "agent-$AGENT_ID")"

# Cloudflare Tunnel
if command -v cloudflared &>/dev/null; then
  cloudflared tunnel run "$TUNNEL_NAME" &>/tmp/clawrain-tunnel-$AGENT_ID.log &
fi

# clawrain-agent
if command -v clawrain-agent &>/dev/null && [[ -f "$AGENT_DIR/setup-config.json" ]]; then
  nohup clawrain-agent start --config "$AGENT_DIR/setup-config.json" --port 8000 \
    >> /tmp/clawrain-agent-$AGENT_ID.log 2>&1 &
fi

# OpenClaw agent
cd "$AGENT_DIR"
exec openclaw agent
STARTSCRIPT

chmod +x "$WORKSPACE_DIR/start.sh"

# ─── DONE ───────────────────────────────────────────────────────────────────
echo ""
log_info "✅ Setup complete!"
echo ""
echo "  Workspace: $WORKSPACE_DIR"
echo "  Start:    $WORKSPACE_DIR/start.sh"
echo ""
echo "Logs:"
echo "  tail -f /tmp/clawrain-tunnel-\$(basename $WORKSPACE_DIR).log"
[[ -f "/tmp/clawrain-agent-$AGENT_ID.log" ]] && echo "  tail -f /tmp/clawrain-agent-$AGENT_ID.log"
echo ""
