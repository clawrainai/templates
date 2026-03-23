"""FastAPI metrics server for ClawRain agents."""
import json
import os
from typing import Dict, Any, Optional

from fastapi import FastAPI, Depends, Request
from fastapi.middleware.cors import CORSMiddleware

from .auth import AgentAuth
from .db import MetricsDB
from .manifest import detect_manifest, _find_skill_dirs
from .adapters import positions, portfolio, dsl, scanner, health, history


def create_app(config_path: str = "setup-config.json") -> FastAPI:
    """Create the FastAPI app from a setup-config.json file."""

    # ─── Load config ──────────────────────────────────────────
    with open(config_path) as f:
        config = json.load(f)

    agent_id = config["agent_id"]
    api_key = config["api_key"]
    platform_url = config["platform_url"]
    workspace = os.environ.get("OPENCLAW_WORKSPACE", os.getcwd())

    # ─── Init DB ──────────────────────────────────────────────
    db_path = os.path.join(workspace, "data", "metrics.db")
    db = MetricsDB(db_path)

    # ─── Detect manifest ──────────────────────────────────────
    manifest = detect_manifest(agent_id, workspace, db_path)
    skill_dirs = _find_skill_dirs(workspace)

    # ─── Load strategies from registry files ──────────────────
    def load_strategies():
        """Load all strategies from skill registry files."""
        strats = []
        for skill_dir in skill_dirs:
            import glob
            for pattern in ["*-strategies.json", "config/*-strategies.json"]:
                for filepath in glob.glob(os.path.join(skill_dir, pattern)):
                    try:
                        with open(filepath) as f:
                            reg = json.load(f)
                        for key, val in reg.get("strategies", {}).items():
                            if val.get("enabled", True):
                                val["_key"] = key
                                strats.append(val)
                    except Exception:
                        pass
        return strats

    # ─── Create app ───────────────────────────────────────────
    app = FastAPI(title=f"ClawRain Agent — {manifest.skill}", version=manifest.version)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],  # Hub proxy handles auth
        allow_methods=["GET"],
        allow_headers=["*"],
    )

    auth = AgentAuth(api_key)

    # ─── Routes ───────────────────────────────────────────────

    @app.get("/manifest")
    async def get_manifest(_=Depends(auth)):
        return manifest.to_dict()

    @app.get("/health")
    async def get_health():
        # Health is public (no auth) for uptime monitors
        return health.fetch_health(skill_dirs, config)

    @app.get("/positions")
    async def get_positions(_=Depends(auth)):
        strats = load_strategies()
        return positions.fetch_positions(strats)

    @app.get("/portfolio")
    async def get_portfolio(_=Depends(auth)):
        strats = load_strategies()
        return portfolio.fetch_portfolio(strats)

    @app.get("/dsl-status")
    async def get_dsl_status(_=Depends(auth)):
        return dsl.fetch_dsl_status(skill_dirs)

    @app.get("/scanner")
    async def get_scanner(_=Depends(auth)):
        return scanner.fetch_scanner(skill_dirs)

    @app.get("/pnl-history")
    async def get_pnl_history(_=Depends(auth)):
        return history.fetch_pnl_history(db)

    @app.get("/trades")
    async def get_trades(_=Depends(auth)):
        return history.fetch_trades(db)

    return app
