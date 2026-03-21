# Contributing to ClawRain Templates

## Creating a new template

### Structure

```
templates/
├── setup.sh                    ← Universal (don't edit)
├── base/                       ← Base workspace
│   ├── identity.md
│   ├── soul.md
│   ├── AGENTS.md
│   └── memory/
│
└── {market}/
    └── {service}/
        └── {strategy-version}/
            ├── config.json      ← Strategy config
            ├── skills/          ← Strategy skills
            └── memory/
                └── template.md  ← Memory template
```

### Steps

1. Fork `clawrainai/templates`
2. Add your template under the correct market/service directory
3. Test locally with a real config.json
4. Submit PR

### Requirements

- `config.json` must be valid (matches schema)
- `setup.sh` must work with the template
- All required skills must be present
- Memory template must have date placeholder

### Checklist

- [ ] config.json valid
- [ ] setup.sh compatible
- [ ] skills/ complete
- [ ] memory/template.md exists
- [ ] README updated (if adding new market/service)
