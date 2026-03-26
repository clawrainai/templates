#!/bin/bash
# setup-strategy.sh — Creates crons for the trading strategy
# Usage: bash setup-strategy.sh setup-config.json

CONFIG="$1"
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: setup-config.json not found"
  exit 1
fi

AGENT_ID=$(jq -r '.agent_id' "$CONFIG")
WORKSPACE_DIR="$HOME/.clawrain/$AGENT_ID"

# Check if custom strategy
CUSTOM_STRATEGY=$(jq -e '.customStrategy' "$CONFIG" 2>/dev/null)
STRATEGY_ID=""
if [[ -f "$WORKSPACE_DIR/.config/senpi/strategy.json" ]]; then
  STRATEGY_ID=$(jq -r '.strategyId' "$WORKSPACE_DIR/.config/senpi/strategy.json" 2>/dev/null)
fi

echo "[INFO] Setting up crons..."

# Determine strategy identifier for cron name
if [[ -n "$STRATEGY_ID" ]]; then
  CRON_NAME="clawrain-custom-${AGENT_ID:0:8}"
  echo "[INFO] Custom strategy detected: $STRATEGY_ID"
else
  SKILL_PATH=$(jq -r '.skill.path' "$CONFIG")
  CRON_NAME="clawrain-$(basename "$SKILL_PATH")-${AGENT_ID:0:8}"
fi

# Create cron wrapper
CRON_SCRIPT="/tmp/clawrain-cron-${AGENT_ID:0:8}.sh"

if [[ -n "$STRATEGY_ID" ]]; then
  # Custom strategy cron - uses Senpi MCP
  cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
# Cron wrapper for ClawRain custom strategy
AGENT_DIR="$HOME/.clawrain/AGENT_ID_PLACEHOLDER"
export OPENCLAW_WORKSPACE="$AGENT_DIR"

# Load Senpi credentials
SENPI_CREDS="$AGENT_DIR/.config/senpi/credentials.json"
STRATEGY_JSON="$AGENT_DIR/.config/senpi/strategy.json"

if [[ ! -f "$SENPI_CREDS" ]] || [[ ! -f "$STRATEGY_JSON" ]]; then
  exit 0
fi

SENPI_AUTH_TOKEN=$(jq -r '.apiKey' "$SENPI_CREDS")
STRATEGY_ID=$(jq -r '.strategyId' "$STRATEGY_JSON")
SENPI_MCP_URL="https://mcp.prod.senpi.ai/mcp"

# Call Senpi MCP to check strategy status and execute
MCP_REQUEST=$(cat << MCPJSON
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"strategy_get_status","arguments":{"strategyId":"$STRATEGY_ID"}}}
MCPJSON
)

curl -s -X POST "$SENPI_MCP_URL" \
  -H "Authorization: Bearer $SENPI_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$MCP_REQUEST" > /dev/null 2>&1

echo "[$(date)] Custom strategy $STRATEGY_ID checked"
CRONEOF

  sed -i "s|AGENT_ID_PLACEHOLDER|$AGENT_ID|g" "$CRON_SCRIPT"

else
  # Catalog strategy cron - uses Python scanner
  SKILL_PATH=$(jq -r '.skill.path' "$CONFIG")
  STRATEGY=$(basename "$SKILL_PATH")

  cat > "$CRON_SCRIPT" << CRONEOF
#!/bin/bash
AGENT_DIR="$HOME/.clawrain/$AGENT_ID"
SKILL_DIR="$AGENT_DIR/skills/$STRATEGY"
export OPENCLAW_WORKSPACE="$AGENT_DIR"
export PYTHONPATH="$SKILL_DIR/scripts:$PYTHONPATH"
cd "$SKILL_DIR"
python3 scripts/*-scanner.py 2>&1
CRONEOF

fi

chmod +x "$CRON_SCRIPT"

# Install cron via systemd timer (more reliable than cron on VPS)
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

# Stop existing timer if any
systemctl --user stop "clawrain-${CRON_NAME}.timer" 2>/dev/null || true

# Service
cat > "$UNIT_DIR/clawrain-${CRON_NAME}.service" << EOF
[Unit]
Description=ClawRain ${CRON_NAME} Scanner
[Service]
Type=oneshot
ExecStart=$CRON_SCRIPT
WorkingDirectory=$WORKSPACE_DIR
Environment=OPENCLAW_WORKSPACE=$WORKSPACE_DIR
Environment=HOME=$HOME
EOF

# Timer (every 3 minutes)
cat > "$UNIT_DIR/clawrain-${CRON_NAME}.timer" << EOF
[Unit]
Description=ClawRain ${CRON_NAME} Scanner Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=180
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now "clawrain-${CRON_NAME}.timer" 2>/dev/null || true

echo "[DONE] Crons configured: $CRON_NAME"
echo "[INFO] Timer: every 3 minutes"
