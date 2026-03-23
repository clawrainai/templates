"""DSL trailing stop status — reads local state files."""
import json
import glob
import os
from typing import Dict, Any, List


def fetch_dsl_status(skill_dirs: List[str]) -> Dict[str, Any]:
    """Read DSL state files from skill directories.
    
    Returns StatusGrid-compatible format:
    { items: [{ label, status, detail }] }
    """
    items = []

    for skill_dir in skill_dirs:
        # Look for DSL state files in multiple locations
        patterns = [
            os.path.join(skill_dir, "state", "*", "*.json"),
            os.path.join(skill_dir, "dsl", "*", "*.json"),
            os.path.join(skill_dir, "dsl-*.json"),
        ]

        for pattern in patterns:
            for filepath in glob.glob(pattern):
                try:
                    with open(filepath) as f:
                        state = json.load(f)

                    if not state.get("active", False):
                        continue

                    asset = state.get("asset", os.path.basename(filepath).replace(".json", ""))
                    phase = state.get("phase", "?")
                    direction = state.get("direction", "?")
                    entry = state.get("entryPrice", 0)
                    floor = state.get("floorPrice", 0)
                    high_water = state.get("highWaterPrice", entry)
                    tier_idx = state.get("currentTierIndex", -1)

                    status = "ok" if phase == 2 else "warning" if phase == 1 else "error"
                    detail = (
                        f"{direction} @ {entry:.4f} | "
                        f"Floor: {floor:.4f} | "
                        f"HW: {high_water:.4f} | "
                        f"Phase {phase} | Tier {tier_idx + 1}"
                    )

                    items.append({
                        "label": asset,
                        "status": status,
                        "detail": detail,
                    })
                except (json.JSONDecodeError, IOError):
                    continue

    if not items:
        items.append({"label": "No active positions", "status": "neutral", "detail": "DSL idle"})

    return {"items": items}
