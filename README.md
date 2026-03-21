# ClawRain Agent Templates

> OpenClaw workspace templates — git clone and trade.

## Quick Start

```
1. Download config.json from ClawRain
2. Run setup:
   curl -fsSL https://raw.githubusercontent.com/clawrainai/templates/main/setup.sh | bash -s -- --config config.json
3. Launch agent:
   openclaw agent
```

## What this does

```
config.json          ← Your config from ClawRain
       ↓
setup.sh             ← Fetches strategy from registry
       ↓
registry clone       ← github.com/clawrainai/agents
       ↓
skills installed     ← fox.js, onboard, tools
       ↓
openclaw agent       ← Agent boots, onboard triggers
       ↓
TRADING
```

## Template Structure

```
templates/
├── setup.sh                    ← Universal bootstrap
├── base/                       ← Base OpenClaw workspace
│   ├── identity.md
│   ├── soul.md
│   ├── AGENTS.md
│   └── memory/
│
├── hyperliquid/
│   └── senpi/
│       ├── fox-v2.0/
│       │   ├── config.json      ← Strategy-specific config
│       │   └── ...
│       └── orca-v1.2/
│           └── ...
│
└── solana/
    └── ...
```

## For Developers

See [CONTRIBUTING.md](./CONTRIBUTING.md) to create new templates.

## Registry

Templates pull from: `github.com/clawrainai/agents`
