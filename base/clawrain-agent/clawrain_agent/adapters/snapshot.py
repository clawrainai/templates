"""Snapshot push — sends daily summary to ClawRain Hub."""
import httpx
from typing import Dict, Any, Optional
from ..db import MetricsDB


def push_snapshot(
    db: MetricsDB,
    platform_url: str,
    agent_id: str,
    api_key: str,
) -> Dict[str, Any]:
    """Push the latest snapshot to ClawRain Hub.
    
    Called by: clawrain-agent snapshot (CLI command / cron)
    """
    latest = db.get_latest_snapshot()
    if not latest:
        return {"ok": False, "message": "No snapshot data available"}

    url = f"{platform_url}/api/agent/{agent_id}/snapshot"
    try:
        resp = httpx.post(
            url,
            json={
                "date": latest["date"],
                "balance": latest["balance"],
                "pnl_day": latest["pnl_day"],
                "pnl_total": latest["pnl_total"],
                "positions": latest["positions"],
                "trades_count": latest["trades_count"],
                "drawdown": latest["drawdown"],
            },
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10,
        )
        return resp.json()
    except Exception as e:
        return {"ok": False, "message": str(e)}
