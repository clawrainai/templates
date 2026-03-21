#!/bin/bash
# ClawRain Agent Setup Script
# Usage: ./setup.sh --config config.json
# Or:    curl -fsSL https://raw.githubusercontent.com/clawrainai/templates/main/setup.sh | bash -s -- --config config.json

set -e

REGISTRY="https://github.com/clawrainai/agents"
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
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Validate config
if [[ -z "$CONFIG_PATH" ]]; then
  echo "Error: --config is required"
  usage
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Error: config file not found: $CONFIG_PATH"
  exit 1
fi

# Validate jq is available
if ! command -v jq &> /dev/null; then
  echo "Installing jq..."
  sudo apt-get update && sudo apt-get install -y jq
fi

# Parse config
AGENT_ID=$(jq -r '.agentId' "$CONFIG_PATH")
MARKET=$(jq -r '.market' "$CONFIG_PATH")
SERVICE=$(jq -r '.service' "$CONFIG_PATH")
STRATEGY=$(jq -r '.strategy' "$CONFIG_PATH")
STRATEGY_KEBAB=$(echo "$STRATEGY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '.' '-')

echo "ClawRain Agent Setup"
echo "===================="
echo "Agent ID:   $AGENT_ID"
echo "Market:     $MARKET"
echo "Service:    $SERVICE"
echo "Strategy:   $STRATEGY"
echo ""

# Set workspace dir
if [[ -z "$WORKSPACE_DIR" ]]; then
  WORKSPACE_DIR="$HOME/.openclaw/workspace-$AGENT_ID"
fi

echo "Workspace:  $WORKSPACE_DIR"
echo ""

# Check if already exists
if [[ -d "$WORKSPACE_DIR" ]]; then
  read -p "Workspace already exists. Overwrite? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
  rm -rf "$WORKSPACE_DIR"
fi

# Create workspace
echo "Creating workspace..."
mkdir -p "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR/memory"
mkdir -p "$WORKSPACE_DIR/.config"

# Clone registry (shallow)
echo "Fetching strategy from registry..."
git clone --depth 1 "$REGISTRY" "$WORKSPACE_DIR/registry"

# Copy strategy files
STRATEGY_DIR="$WORKSPACE_DIR/registry/$MARKET/$SERVICE/$STRATEGY_KEBAB"
if [[ ! -d "$STRATEGY_DIR" ]]; then
  echo "Error: Strategy not found in registry: $MARKET/$SERVICE/$STRATEGY"
  exit 1
fi

# Copy strategy config
cp "$STRATEGY_DIR/config.json" "$WORKSPACE_DIR/strategy.json"

# Copy skills
SKILLS_DIR="$STRATEGY_DIR/skills"
if [[ -d "$SKILLS_DIR" ]]; then
  cp -r "$SKILLS_DIR" "$WORKSPACE_DIR/skills"
fi

# Copy memory template
MEMORY_TEMPLATE="$STRATEGY_DIR/memory/template.md"
if [[ -f "$MEMORY_TEMPLATE" ]]; then
  TODAY=$(date +%Y-%m-%d)
  cp "$MEMORY_TEMPLATE" "$WORKSPACE_DIR/memory/$TODAY.md"
fi

# Copy user config
cp "$CONFIG_PATH" "$WORKSPACE_DIR/config.json"

# Create base files
cat > "$WORKSPACE_DIR/identity.md" << 'EOF'
# Identity

## Agent
- Name: FILL THIS
- Role: Trading agent
- Emoji: FILL THIS

## Personality
FILL THIS
EOF

cat > "$WORKSPACE_DIR/soul.md" << 'EOF'
# Soul

## Vibe
FILL THIS

## Principles
- Be helpful, not performative
- Be resourceful before asking
- Earn trust through competence

## Boundaries
- Private things stay private
- Never send half-baked replies
- Be careful in group chats
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
1. Boot with: openclaw agent
2. On first boot: senpi-onboard triggers automatically
3. Trading begins when funded
4. Push metrics to GenosDB every 30s

## Memory
Write daily notes in memory/YYYY-MM-DD.md

## Skills
Your skills are in: skills/
EOF

# Cleanup registry copy (we only needed strategy files)
rm -rf "$WORKSPACE_DIR/registry"

# Make config immutable (user shouldn't edit)
chmod 444 "$WORKSPACE_DIR/config.json"
chmod 444 "$WORKSPACE_DIR/strategy.json"

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Edit identity.md and soul.md"
echo "2. Launch: openclaw agent --workspace $WORKSPACE_DIR"
echo "3. Fund your agent wallet (address shown on first boot)"
echo ""
echo "Files:"
ls -la "$WORKSPACE_DIR"
