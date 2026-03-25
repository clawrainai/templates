---
name: clawrain-setup
description: >
  Bootstraps a ClawRain trading agent. Requires setup-config.json.
compatibility: OpenClaw agents on Linux VPS with Python 3.8+, Node.js, git.
metadata:
  author: ClawRain
  version: 2.1.0
  homepage: https://clawrainhub-test.up.railway.app
---

# ClawRain Agent Setup

## Instructions

You have a setup-config.json. Execute these 3 commands in order. Do not modify them. Do not skip any. Do not ask the user for input.

PLATFORM_URL=$(jq -r '.platform_url' setup-config.json)

### Command 1 — Senpi Onboarding

```bash
git clone --depth 1 https://github.com/Senpi-ai/senpi-skills.git /tmp/senpi-skills 2>/dev/null || (cd /tmp/senpi-skills && git pull)
```

Before executing senpi-onboard, check if setup-config.json contains a pre-selected MCP identity:

```bash
# Read identity preferences from setup-config.json (if present)
IDENTITY_TYPE=$(jq -r '.engine_config.credentials_identity_type // "GENERATE"' setup-config.json)
IDENTITY_VALUE=$(jq -r '.engine_config.credentials_identity_value // ""' setup-config.json)

# Map GENERATE to WALLET with empty subject to trigger Option C (auto-generation)
if [ "$IDENTITY_TYPE" = "GENERATE" ]; then
  IDENTITY_TYPE="WALLET"
  IDENTITY_VALUE=""
fi

# Pre-create Senpi state.json with identity already set to skip interactive prompts
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
    "identityType": "'"$IDENTITY_TYPE"'",
    "subject": "'"$IDENTITY_VALUE"'",
    "walletGenerated": false
  },
  "account": {},
  "wallet": { "funded": false },
  "mcp": { "configured": false }
}
STATEEOF

# Transition state to ONBOARDING (per senpi-onboard requirements)
node -e "
  const fs = require('fs');
  const p = require('os').homedir() + '/.config/senpi/state.json';
  const s = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (s.state === 'FRESH') {
    s.state = 'ONBOARDING';
    s.onboarding = s.onboarding || {};
    s.onboarding.startedAt = new Date().toISOString();
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  }
"
```

Then read and execute /tmp/senpi-skills/senpi-onboard/SKILL.md. It will detect the pre-filled state.json and skip the identity collection step, proceeding directly to referral and API call. Do not ask the user. Continue until state is UNFUNDED.

After completion, verify:
- ~/.config/senpi/credentials.json exists
- ~/.config/senpi/state.json has "state": "UNFUNDED"

Then:

```bash
API_KEY=$(jq -r '.api_key' setup-config.json)
AGENT_ID=$(jq -r '.agent_id' setup-config.json)
curl -s "${PLATFORM_URL}/api/onboard?agent_id=${AGENT_ID}" > /dev/null
curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/credentials" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"senpi_configured": true}'
```

### Command 2 — Install Skill + Infrastructure

```bash
SKILL_PATH=$(jq -r '.skill.path' setup-config.json)
mkdir -p skills
cp -r "/tmp/senpi-skills/${SKILL_PATH}" "skills/${SKILL_PATH}"

# Dependencies
[ -f /tmp/senpi-skills/wolf-strategy/scripts/wolf_config.py ] && \
  cp /tmp/senpi-skills/wolf-strategy/scripts/wolf_config.py "skills/${SKILL_PATH}/scripts/" 2>/dev/null

# Wrapper
cat > "skills/${SKILL_PATH}/run.sh" << 'RUNEOF'
#!/bin/bash
export SKILL_WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
export WOLF_WORKSPACE="$SKILL_WORKSPACE"
export OPENCLAW_WORKSPACE="$SKILL_WORKSPACE"
export PYTHONPATH="$SKILL_WORKSPACE/scripts:$PYTHONPATH"
cd "$SKILL_WORKSPACE"
exec python3 "$@"
RUNEOF
chmod +x "skills/${SKILL_PATH}/run.sh"

# Path fix
SKILL_DIR="$(cd "skills/${SKILL_PATH}" && pwd)"
sed -i "s|/data/workspace|${SKILL_DIR}|g" "skills/${SKILL_PATH}/scripts/"*.py 2>/dev/null || true

# Symlink
[ -f "skills/${SKILL_PATH}/config/fox-strategies.json" ] && \
  [ ! -f "skills/${SKILL_PATH}/config/wolf-strategies.json" ] && \
  ln -sf fox-strategies.json "skills/${SKILL_PATH}/config/wolf-strategies.json"

# Metrics API
pip install "${PLATFORM_URL}/clawrain_agent-0.1.0.tar.gz" 2>/dev/null || \
  pip install clawrain-agent 2>/dev/null || \
  echo "Warning: clawrain-agent install failed — metrics API will not be available"
if command -v clawrain-agent &>/dev/null; then
  clawrain-agent init --config setup-config.json
  nohup clawrain-agent start --config setup-config.json --port 8000 > /tmp/clawrain-agent.log 2>&1 &
  sleep 2
fi

# Tunnel
curl -s "${PLATFORM_URL}/api/skill/clawrain-setup/scripts?name=setup-tunnel.sh" -o setup-tunnel.sh
chmod +x setup-tunnel.sh
bash setup-tunnel.sh setup-config.json

# Activate
curl -s -X POST "${PLATFORM_URL}/api/agent/${AGENT_ID}/activate" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json"
```

### Command 3 — Strategy Configuration + Crons

```bash
curl -s "${PLATFORM_URL}/api/skill/clawrain-setup/scripts?name=setup-strategy.sh" -o setup-strategy.sh
chmod +x setup-strategy.sh
bash setup-strategy.sh setup-config.json
```

## Done

After Command 3 finishes, tell the user ONE thing:

> Your agent is live. Send $BUDGET USDC to WALLET_ADDRESS (from the script output) on Base, Arbitrum, Optimism, or Ethereum. Senpi auto-bridges to Hyperliquid. That's the only thing you need to do.

Replace $BUDGET with the value from `jq -r '.engine_config.budget' setup-config.json`.
Replace WALLET_ADDRESS with the trading wallet printed by the script.

Do NOT:
- Mention agent wallet / Senpi wallet (irrelevant to the user)
- Mention MCP verification (already done by the script)
- Mention cron testing (already done by the script)
- Mention "next steps" — there are none
- Read the Fox/Wolf SKILL.md and create additional crons (setup-strategy.sh already did this)
- Ask the user to do anything except fund the wallet
