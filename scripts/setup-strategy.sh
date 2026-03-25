#!/bin/bash
# setup-strategy.sh — Creates crons for the trading strategy
# Usage: bash setup-strategy.sh setup-config.json

CONFIG="$1"
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: setup-config.json not found"
  exit 1
fi

SKILL_PATH=$(jq -r '.skill.path' "$CONFIG")
STRATEGY=$(basename "$SKILL_PATH")
AGENT_ID=$(jq -r '.agent_id' "$CONFIG")

echo "[INFO] Setting up crons for $STRATEGY..."

# Create cron wrapper that runs the scanner
CRON_SCRIPT="/tmp/clawrain-cron-${AGENT_ID}.sh"
cat > "$CRON_SCRIPT" << 'CRONEOF'
#!/bin/bash
# Cron wrapper for ClawRain trading agent
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$AGENT_DIR/skills/STRATEGY_PLACEHOLDER"
export OPENCLAW_WORKSPACE="$AGENT_DIR"
export PYTHONPATH="$SKILL_DIR/scripts:$PYTHONPATH"
cd "$SKILL_DIR"
python3 scripts/*-scanner.py 2>&1
CRONEOF

# Replace placeholder
sed -i "s/STRATEGY_PLACEHOLDER/$STRATEGY/g" "$CRON_SCRIPT"
chmod +x "$CRON_SCRIPT"

# Check if openclaw cron is available
if command -v openclaw &>/dev/null; then
  echo "[INFO] Creating OpenClaw cron for $STRATEGY..."
  
  # Run every 3 minutes
  openclaw cron add \
    --name "clawrain-$STRATEGY" \
    --schedule "*/3 * * * *" \
    --command "bash $CRON_SCRIPT" \
    2>/dev/null || {
    echo "[WARN] Failed to create OpenClaw cron, using systemd timer instead"
    create_systemd_timer
  }
else
  echo "[INFO] OpenClaw not available, using systemd timer..."
  create_systemd_timer
fi

echo "[DONE] Crons configured for $STRATEGY"

# Verify cron
if command -v openclaw &>/dev/null; then
  openclaw cron list 2>/dev/null | grep -i "clawrain" || true
fi

create_systemd_timer() {
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  
  # Service
  cat > "$UNIT_DIR/clawrain-$STRATEGY.service" << EOF
[Unit]
Description=ClawRain $STRATEGY Scanner
[Service]
Type=oneshot
ExecStart=$CRON_SCRIPT
WorkingDirectory=$HOME/.clawrain/$AGENT_ID
Environment=OPENCLAW_WORKSPACE=$HOME/.clawrain/$AGENT_ID
EOF

  # Timer (every 3 minutes)
  cat > "$UNIT_DIR/clawrain-$STRATEGY.timer" << EOF
[Unit]
Description=ClawRain $STRATEGY Scanner Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=180
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now clawrain-$STRATEGY.timer 2>/dev/null || true
  echo "[INFO] Systemd timer created for $STRATEGY"
}
