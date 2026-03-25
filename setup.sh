#!/bin/bash
# ClawRain Agent Setup
# Usage: curl ...setup.sh | bash -s -- --agent-id ID
# The script fetches SKILL.md and executes the setup commands

set -e

AGENT_ID=""
PLATFORM_URL="${PLATFORM_URL:-https://clawrainhub-test.up.railway.app}"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

if [[ -z "$AGENT_ID" ]]; then
  echo "Error: --agent-id required"
  exit 1
fi

# ─── Decode setup-config from environment ──────────────────────────────────
CONFIG_JSON="${CLAWRAIN_CONFIG:-}"
if [[ -z "$CONFIG_JSON" ]]; then
  echo "Error: CLAWRAIN_CONFIG environment variable not set"
  exit 1
fi

echo "$CONFIG_JSON" | base64 -d > setup-config.json 2>/dev/null || {
  echo "Error: Failed to decode CLAWRAIN_CONFIG"
  exit 1
}

echo "[INFO] Setup config decoded"
echo "[INFO] Agent ID: $AGENT_ID"

PLATFORM_URL=$(jq -r '.platform_url // "https://clawrainhub-test.up.railway.app"' setup-config.json)
SKILL_PATH=$(jq -r '.skill.path' setup-config.json)
STRATEGY=$(basename "$SKILL_PATH")
API_KEY=$(jq -r '.api_key' setup-config.json)
WORKSPACE_DIR="$HOME/.clawrain/$AGENT_ID"

echo "========================================"
echo "  ClawRain Agent Setup"
echo "  Strategy: $STRATEGY"
echo "  Agent: $AGENT_ID"
echo "  Platform: $PLATFORM_URL"
echo "========================================"

mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# ─── STEP 1: Senpi Onboarding ─────────────────────────────────────────────
echo "[STEP 1/3] Senpi Onboarding..."

# Clone senpi-skills
if [[ ! -d /tmp/senpi-skills ]]; then
  git clone --depth 1 https://github.com/Senpi-ai/senpi-skills.git /tmp/senpi-skills 2>/dev/null || \
    (cd /tmp/senpi-skills && git pull)
fi

# Read identity from config
IDENTITY_TYPE=$(jq -r '.engine_config.credentials_identity_type // "GENERATE"' setup-config.json)
IDENTITY_VALUE=$(jq -r '.engine_config.credentials_identity_value // ""' setup-config.json)

# Map GENERATE to WALLET with empty subject for auto-generation
if [[ "$IDENTITY_TYPE" = "GENERATE" ]]; then
  IDENTITY_TYPE="WALLET"
  IDENTITY_VALUE=""
fi

# Pre-create Senpi state.json
mkdir -p ~/.config/senpi
cat > ~/.config/senpi/state.json << 'STATEEOF'
{
  "version": "1.0.0",
  "state": "FRESH",
  "error": null,
  "onboarding": {
    "step": "IDENTITY",
    "startedAt": null,
    "completedAt": null,
    "identityType": "IDENTITY_TYPE_PLACEHOLDER",
    "subject": "IDENTITY_VALUE_PLACEHOLDER",
    "walletGenerated": false
  },
  "account": {},
  "wallet": { "funded": false },
  "mcp": { "configured": false }
}
STATEEOF

# Replace placeholders
sed -i "s/IDENTITY_TYPE_PLACEHOLDER/$IDENTITY_TYPE/" ~/.config/senpi/state.json
sed -i "s/IDENTITY_VALUE_PLACEHOLDER/$IDENTITY_VALUE/" ~/.config/senpi/state.json

# Transition to ONBOARDING state
node -e "
const fs = require('fs');
const p = process.env.HOME + '/.config/senpi/state.json';
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
if (s.state === 'FRESH') {
  s.state = 'ONBOARDING';
  s.onboarding = s.onboarding || {};
  s.onboarding.startedAt = new Date().toISOString();
  fs.writeFileSync(p, JSON.stringify(s, null, 2));
}
"

# Execute Senpi onboarding skill directly (bash version)
SENPI_ONBOARD_SCRIPT=$(cat << 'SENPIEOF'
#!/bin/bash
# Senpi onboarding - executes the GraphQL mutation to create agent account

# Check if already onboarded
STATE_FILE="$HOME/.config/senpi/state.json"
CREDS_FILE="$HOME/.config/senpi/credentials.json"

if [[ -f "$CREDS_FILE" ]]; then
  echo "[INFO] Senpi already onboarded (credentials exist)"
  exit 0
fi

# Read from state.json
IDENTITY_TYPE=$(jq -r '.onboarding.identityType // "WALLET"' "$STATE_FILE")
SUBJECT=$(jq -r '.onboarding.subject // ""' "$STATE_FILE")

# GraphQL mutation
GRAPHQL_URL="https://moxie-backend.prod.senpi.ai/graphql"
REFERRAL_CODE="clawrain"

MUTATION='{"query":"mutation CreateAgentStubAccount($input: CreateAgentStubAccountInput!) { CreateAgentStubAccount(input: $input) { apiKey userId referralCode } }","variables":{"input":{"identityType":"'"$IDENTITY_TYPE"'","from":"WALLET","subject":"'"$SUBJECT"'","referralCode":"'"$REFERRAL_CODE"'"}}}'

RESPONSE=$(curl -s -X POST "$GRAPHQL_URL" \
  -H "Content-Type: application/json" \
  -d "$MUTATION")

# Parse response
if echo "$RESPONSE" | jq -e '.data.CreateAgentStubAccount.apiKey' >/dev/null 2>&1; then
  API_KEY=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.apiKey')
  USER_ID=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.userId')
  REF_CODE=$(echo "$RESPONSE" | jq -r '.data.CreateAgentStubAccount.referralCode')

  mkdir -p ~/.config/senpi

  cat > "$CREDS_FILE" << 'CREDFILE'
{
  "apiKey": "API_KEY_PLACEHOLDER",
  "userId": "USER_ID_PLACEHOLDER",
  "referralCode": "REF_CODE_PLACEHOLDER"
}
CREDFILE

  sed -i "s/API_KEY_PLACEHOLDER/$API_KEY/" "$CREDS_FILE"
  sed -i "s/USER_ID_PLACEHOLDER/$USER_ID/" "$CREDS_FILE"
  sed -i "s/REF_CODE_PLACEHOLDER/$REF_CODE/" "$CREDS_FILE"

  # Update state
  node -e "
const fs = require('fs');
const p = process.env.HOME + '/.config/senpi/state.json';
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
s.state = 'UNFUNDED';
s.account = { apiKey: '$API_KEY', userId: '$USER_ID', referralCode: '$REF_CODE' };
fs.writeFileSync(p, JSON.stringify(s, null, 2));
"

  echo "[INFO] Senpi onboarding complete: User $USER_ID"
else
  echo "[ERROR] Senpi onboarding failed"
  echo "$RESPONSE"
  exit 1
fi
SENPIEOF
)

bash -c "$SENPI_ONBOARD_SCRIPT"

# Verify
if [[ ! -f ~/.config/senpi/credentials.json ]]; then
  echo "[ERROR] Senpi credentials not created"
  exit 1
fi

curl -s "${PLATFORM_URL}/api/onboard?agent_id=${AGENT_ID}" > /dev/null
curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/credentials" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"senpi_configured": true}' > /dev/null || true

echo "[STEP 1/3] Senpi Onboarding — DONE"

# ─── STEP 2: Install Skill + Infrastructure ───────────────────────────────
echo "[STEP 2/3] Installing skill..."

mkdir -p skills

# Copy skill
cp -r "/tmp/senpi-skills/${SKILL_PATH}" "skills/${SKILL_PATH}" 2>/dev/null || {
  echo "[ERROR] Failed to copy skill from /tmp/senpi-skills/${SKILL_PATH}"
  exit 1
}

# Copy wolf_config.py if exists
if [[ -f /tmp/senpi-skills/wolf-strategy/scripts/wolf_config.py ]]; then
  cp /tmp/senpi-skills/wolf-strategy/scripts/wolf_config.py "skills/${SKILL_PATH}/scripts/" 2>/dev/null || true
fi

# Create run wrapper
cat > "skills/${SKILL_PATH}/run.sh" << 'WRAPPEREOF'
#!/bin/bash
SKILL_WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
export WOLF_WORKSPACE="$SKILL_WORKSPACE"
export OPENCLAW_WORKSPACE="$SKILL_WORKSPACE"
export PYTHONPATH="$SKILL_WORKSPACE/scripts:$PYTHONPATH"
cd "$SKILL_WORKSPACE"
exec python3 "$@"
WRAPPEREOF
chmod +x "skills/${SKILL_PATH}/run.sh"

# Fix hardcoded paths
SKILL_DIR="$(cd "skills/${SKILL_PATH}" && pwd)"
find "skills/${SKILL_PATH}/scripts/" -name "*.py" -exec sed -i "s|/data/workspace|${SKILL_DIR}|g" {} \; 2>/dev/null || true

# Symlink fox -> wolf if needed
if [[ -f "skills/${SKILL_PATH}/config/fox-strategies.json" ]] && \
   [[ ! -f "skills/${SKILL_PATH}/config/wolf-strategies.json" ]]; then
  ln -sf fox-strategies.json "skills/${SKILL_PATH}/config/wolf-strategies.json"
fi

# Fetch and run setup-tunnel.sh
curl -s "${PLATFORM_URL}/api/skill/clawrain-setup/scripts?name=setup-tunnel.sh" -o setup-tunnel.sh
chmod +x setup-tunnel.sh
bash setup-tunnel.sh setup-config.json

# Activate agent
curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/activate" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" > /dev/null || true

echo "[STEP 2/3] Skill + Infrastructure — DONE"

# ─── STEP 3: Strategy Configuration + Crons ───────────────────────────────
echo "[STEP 3/3] Setting up crons..."

curl -s "${PLATFORM_URL}/api/skill/clawrain-setup/scripts?name=setup-strategy.sh" -o setup-strategy.sh
chmod +x setup-strategy.sh
bash setup-strategy.sh setup-config.json

echo "[STEP 3/3] Crons — DONE"

# ─── Done ──────────────────────────────────────────────────────────────────
WALLET_ADDR=$(jq -r '.wallet.address' ~/.config/senpi/credentials.json 2>/dev/null || echo "unknown")
BUDGET=$(jq -r '.engine_config.budget // "1000"' setup-config.json)

echo ""
echo "========================================"
echo "  ClawRain Agent Ready!"
echo "========================================"
echo ""
echo "Your agent is live."
echo ""
echo "Send $BUDGET USDC to $WALLET_ADDR"
echo "on Base, Arbitrum, Optimism, or Ethereum."
echo "Senpi auto-bridges to Hyperliquid."
echo ""
echo "That's the only thing you need to do."
echo ""
