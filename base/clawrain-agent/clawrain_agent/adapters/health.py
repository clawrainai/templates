"""Health check — local system status."""
import os
import subprocess
import json
from datetime import datetime, timezone
from typing import Dict, Any, List


def fetch_health(skill_dirs: List[str], config: Dict[str, Any]) -> Dict[str, Any]:
    """Check agent health status.
    
    Returns StatusGrid-compatible format:
    { items: [{ label, status, detail }] }
    """
    items = []

    # 1. MCP connection
    try:
        result = subprocess.run(
            ["mcporter", "list"], capture_output=True, text=True, timeout=5
        )
        has_senpi = "senpi" in result.stdout.lower()
        items.append({
            "label": "Senpi MCP",
            "status": "ok" if has_senpi else "error",
            "detail": "Connected" if has_senpi else "Not found in mcporter list",
        })
    except Exception:
        items.append({"label": "Senpi MCP", "status": "error", "detail": "mcporter not available"})

    # 2. Skills installed
    for skill_dir in skill_dirs:
        skill_name = os.path.basename(skill_dir)
        exists = os.path.isdir(skill_dir)
        items.append({
            "label": f"Skill: {skill_name}",
            "status": "ok" if exists else "error",
            "detail": skill_dir if exists else "Not installed",
        })

    # 3. Strategy config
    for skill_dir in skill_dirs:
        for pattern in ["*-strategies.json", "config/*-strategies.json"]:
            import glob
            for filepath in glob.glob(os.path.join(skill_dir, pattern)):
                try:
                    with open(filepath) as f:
                        reg = json.load(f)
                    count = len(reg.get("strategies", {}))
                    items.append({
                        "label": "Strategy Config",
                        "status": "ok" if count > 0 else "warning",
                        "detail": f"{count} strategies in {os.path.basename(filepath)}",
                    })
                except Exception:
                    pass

    # 4. Agent uptime
    items.append({
        "label": "Agent API",
        "status": "ok",
        "detail": f"Running — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
    })

    return {"items": items}
