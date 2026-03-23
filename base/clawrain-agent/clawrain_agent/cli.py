"""CLI entry point for clawrain-agent."""
import argparse
import json
import os
import sys


def cmd_init(args):
    """Initialize the agent: create SQLite DB and verify config."""
    config_path = args.config
    if not os.path.exists(config_path):
        print(f"Error: {config_path} not found")
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    print(f"ClawRain Agent — init")
    print(f"  Agent ID: {config['agent_id']}")
    print(f"  Platform: {config['platform_url']}")
    print(f"  Skill:    {config.get('skill', {}).get('path', 'unknown')}")

    # Create DB
    workspace = os.environ.get("OPENCLAW_WORKSPACE", os.getcwd())
    db_path = os.path.join(workspace, "data", "metrics.db")

    from .db import MetricsDB
    db = MetricsDB(db_path)
    print(f"  Database: {db_path} ✓")

    # Detect manifest
    from .manifest import detect_manifest
    manifest = detect_manifest(config["agent_id"], workspace, db_path)
    print(f"  Endpoints detected: {len(manifest.endpoints)}")
    for ep in manifest.endpoints:
        print(f"    {ep.path:20s} → {ep.widget} (priority {ep.priority})")

    # Write state file
    state_path = os.path.join(workspace, ".clawrain-agent.json")
    state = {
        "agent_id": config["agent_id"],
        "config_path": os.path.abspath(config_path),
        "db_path": db_path,
        "workspace": workspace,
        "initialized": True,
    }
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)
    print(f"  State:    {state_path} ✓")
    print(f"\n✅ Ready. Run: clawrain-agent start")


def cmd_start(args):
    """Start the FastAPI metrics server."""
    config_path = args.config
    port = args.port
    host = args.host

    if not os.path.exists(config_path):
        print(f"Error: {config_path} not found. Run 'clawrain-agent init' first.")
        sys.exit(1)

    import uvicorn
    from .server import create_app

    app = create_app(config_path)
    print(f"ClawRain Agent — starting on {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")


def cmd_snapshot(args):
    """Push daily snapshot to ClawRain Hub."""
    config_path = args.config
    if not os.path.exists(config_path):
        print(f"Error: {config_path} not found")
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    workspace = os.environ.get("OPENCLAW_WORKSPACE", os.getcwd())
    db_path = os.path.join(workspace, "data", "metrics.db")

    from .db import MetricsDB
    from .adapters.snapshot import push_snapshot

    db = MetricsDB(db_path)
    result = push_snapshot(db, config["platform_url"], config["agent_id"], config["api_key"])
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(prog="clawrain-agent", description="ClawRain Agent metrics API")
    sub = parser.add_subparsers(dest="command")

    # init
    p_init = sub.add_parser("init", help="Initialize agent (create DB, detect endpoints)")
    p_init.add_argument("--config", default="setup-config.json", help="Path to setup-config.json")

    # start
    p_start = sub.add_parser("start", help="Start the metrics API server")
    p_start.add_argument("--config", default="setup-config.json", help="Path to setup-config.json")
    p_start.add_argument("--port", type=int, default=8000, help="Port (default 8000)")
    p_start.add_argument("--host", default="0.0.0.0", help="Host (default 0.0.0.0)")

    # snapshot
    p_snap = sub.add_parser("snapshot", help="Push daily snapshot to Hub")
    p_snap.add_argument("--config", default="setup-config.json", help="Path to setup-config.json")

    args = parser.parse_args()
    if args.command == "init":
        cmd_init(args)
    elif args.command == "start":
        cmd_start(args)
    elif args.command == "snapshot":
        cmd_snapshot(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
