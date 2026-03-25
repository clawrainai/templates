#!/bin/bash
# setup-tunnel.sh — Creates Cloudflare tunnel for the agent
# Usage: bash setup-tunnel.sh setup-config.json

CONFIG="$1"
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: setup-config.json not found"
  exit 1
fi

AGENT_ID=$(jq -r '.agent_id' "$CONFIG")
PLATFORM_URL=$(jq -r '.platform_url' "$CONFIG")

echo "[INFO] Setting up Cloudflare tunnel for agent $AGENT_ID..."

# Install cloudflared if not present
if ! command -v cloudflared &>/dev/null; then
  echo "[INFO] Installing cloudflared..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64|aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *)       URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
  esac
  curl -L "$URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi

# Create tunnel
TUNNEL_NAME="clawrain-$AGENT_ID"
cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || true

echo "$TUNNEL_NAME" > "$HOME/.config/clawrain/tunnel_name"

TUNNEL_URL="https://${TUNNEL_NAME}.trycloudflare.com"
echo "[INFO] Tunnel ready: $TUNNEL_URL"

# Notify platform of tunnel URL
curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/tunnel" \
  -H "Content-Type: application/json" \
  -d "{\"tunnel_url\": \"$TUNNEL_URL\"}" 2>/dev/null || true

echo "[DONE] Tunnel configured"
