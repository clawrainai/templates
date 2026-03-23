"""Scanner signals — reads local state files."""
import json
import glob
import os
from typing import Dict, Any, List


def fetch_scanner(skill_dirs: List[str]) -> Dict[str, Any]:
    """Read scanner output files from skill directories.
    
    Returns BadgeList-compatible format:
    { items: [{ label, type, score }] }
    """
    items = []

    for skill_dir in skill_dirs:
        # Look for scanner output files
        patterns = [
            os.path.join(skill_dir, "config", "emerging-movers-history.json"),
            os.path.join(skill_dir, "emerging-movers-history.json"),
        ]

        for filepath in patterns:
            if not os.path.exists(filepath):
                continue
            try:
                with open(filepath) as f:
                    data = json.load(f)

                scans = data.get("scans", [])
                if not scans:
                    continue

                # Get the most recent scan
                latest = scans[-1]
                signals = latest.get("signals", latest.get("movers", []))

                for sig in signals[:10]:  # Top 10 signals
                    items.append({
                        "label": sig.get("asset", sig.get("coin", "?")),
                        "type": sig.get("signal", sig.get("type", "UNKNOWN")),
                        "score": sig.get("score", 0),
                    })
            except (json.JSONDecodeError, IOError):
                continue

    if not items:
        items.append({"label": "No signals", "type": "IDLE", "score": 0})

    return {"items": items}
