"""Manifest auto-detection — scans skill dirs to build endpoint list."""
import os
import json
import glob
from typing import List, Optional
from .schemas.manifest import Manifest, ManifestEndpoint


def detect_manifest(
    agent_id: str,
    workspace: str,
    db_path: Optional[str] = None,
) -> Manifest:
    """Auto-detect available endpoints by scanning the workspace.
    
    Looks for:
    - Strategy registry files → /positions, /portfolio
    - DSL state dirs → /dsl-status
    - Scanner history files → /scanner
    - SQLite db → /pnl-history, /trades
    - Always includes /health
    """
    skill_dirs = _find_skill_dirs(workspace)
    endpoints: List[ManifestEndpoint] = []
    skill_name = "unknown"
    skill_version = "0.0"

    # Detect strategy registries → positions + portfolio
    has_strategies = False
    for skill_dir in skill_dirs:
        for pattern in ["*-strategies.json", "config/*-strategies.json"]:
            matches = glob.glob(os.path.join(skill_dir, pattern))
            if matches:
                has_strategies = True
                # Extract skill name from dir
                skill_name = os.path.basename(skill_dir)
                # Try to read version from registry
                try:
                    with open(matches[0]) as f:
                        reg = json.load(f)
                    skill_version = str(reg.get("version", "0.0"))
                except Exception:
                    pass
                break

    if has_strategies:
        endpoints.append(ManifestEndpoint(
            path="/positions", label="Open Positions", widget="DataTable",
            priority=1, refresh=30, source="realtime"
        ))
        endpoints.append(ManifestEndpoint(
            path="/portfolio", label="Portfolio", widget="MetricCard",
            priority=2, refresh=60, source="realtime"
        ))

    # Detect DSL state files → dsl-status
    has_dsl = False
    for skill_dir in skill_dirs:
        patterns = [
            os.path.join(skill_dir, "state", "*", "*.json"),
            os.path.join(skill_dir, "dsl", "*", "*.json"),
        ]
        for pattern in patterns:
            if glob.glob(pattern):
                has_dsl = True
                break

    if has_dsl:
        endpoints.append(ManifestEndpoint(
            path="/dsl-status", label="Trailing Stops", widget="StatusGrid",
            priority=3, refresh=30, source="realtime"
        ))

    # Detect scanner history → scanner
    has_scanner = False
    for skill_dir in skill_dirs:
        for name in ["emerging-movers-history.json", "config/emerging-movers-history.json"]:
            if os.path.exists(os.path.join(skill_dir, name)):
                has_scanner = True
                break

    if has_scanner:
        endpoints.append(ManifestEndpoint(
            path="/scanner", label="Scanner Signals", widget="BadgeList",
            priority=4, refresh=180, source="realtime"
        ))

    # SQLite → history endpoints
    if db_path and os.path.exists(db_path):
        endpoints.append(ManifestEndpoint(
            path="/pnl-history", label="PnL History", widget="LineChart",
            priority=5, refresh=300, source="sqlite"
        ))
        endpoints.append(ManifestEndpoint(
            path="/trades", label="Trade History", widget="DataTable",
            priority=6, refresh=300, source="sqlite"
        ))

    # Always include health
    endpoints.append(ManifestEndpoint(
        path="/health", label="Agent Health", widget="StatusGrid",
        priority=99, refresh=60, source="local"
    ))

    return Manifest(
        agent_id=agent_id,
        skill=skill_name,
        version=skill_version,
        endpoints=endpoints,
    )


def _find_skill_dirs(workspace: str) -> List[str]:
    """Find all installed skill directories."""
    skills_root = os.path.join(workspace, "skills")
    if not os.path.isdir(skills_root):
        return [workspace]  # Fallback: workspace itself is the skill dir

    dirs = []
    for name in os.listdir(skills_root):
        path = os.path.join(skills_root, name)
        if os.path.isdir(path):
            dirs.append(path)

    return dirs if dirs else [workspace]
