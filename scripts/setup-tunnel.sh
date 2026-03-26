#!/bin/bash
# setup-tunnel.sh — Creates Cloudflare tunnel and saves gateway info
# Usage: bash setup-tunnel.sh setup-config.json

CONFIG="$1"
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: setup-config.json not found"
  exit 1
fi

AGENT_ID=$(jq -r '.agent_id' "$CONFIG")
PLATFORM_URL=$(jq -r '.platform_url' "$CONFIG")

echo "[INFO] Setting up Cloudflare tunnel for agent $AGENT_ID..."

# Create config directory
mkdir -p "$HOME/.config/clawrain"

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
TUNNEL_NAME="clawrain-${AGENT_ID:0:8}"
cloudflared tunnel create "$TUNNEL_NAME" --overwrite-dns 2>/dev/null || true
cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_NAME.trycloudflare.com" 2>/dev/null || true

TUNNEL_URL="https://${TUNNEL_NAME}.trycloudflare.com"
echo "[INFO] Tunnel ready: $TUNNEL_URL"

# Save tunnel URL locally
echo "$TUNNEL_URL" > "$HOME/.config/clawrain/tunnel_url"

# Get gateway token from OpenClaw config
GATEWAY_TOKEN=""
if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
  GATEWAY_TOKEN=$(cat "$HOME/.openclaw/openclaw.json" | jq -r '.gateway.auth.token' 2>/dev/null || echo "")
fi

if [[ -z "$GATEWAY_TOKEN" ]]; then
  echo "[WARN] Could not read gateway token from ~/.openclaw/openclaw.json"
  echo "[WARN] Please add gateway_token manually to ~/.config/clawrain/gateway_token"
else
  echo "$GATEWAY_TOKEN" > "$HOME/.config/clawrain/gateway_token"
  echo "[INFO] Gateway token saved"
fi

# Save gateway info locally
cat > "$HOME/.config/clawrain/gateway.json" << EOF
{
  "agent_id": "$AGENT_ID",
  "tunnel_url": "$TUNNEL_URL",
  "gateway_token": "$GATEWAY_TOKEN",
  "gateway_port": 18789,
  "created_at": "$(date -I)"
}
EOF

# Upload gateway info to platform
if [[ -n "$GATEWAY_TOKEN" ]] && [[ -n "$TUNNEL_URL" ]]; then
  echo "[INFO] Uploading gateway info to platform..."
  RESPONSE=$(curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/gateway" \
    -H "Content-Type: application/json" \
    -d "{\"tunnel_url\": \"$TUNNEL_URL\", \"gateway_token\": \"$GATEWAY_TOKEN\"}" 2>/dev/null)
  
  if echo "$RESPONSE" | jq -e '.ok' >/dev/null 2>&1; then
    echo "[INFO] Gateway info uploaded successfully"
  else
    echo "[WARN] Failed to upload gateway info: $RESPONSE"
  fi
fi

echo "[DONE] Tunnel configured"
