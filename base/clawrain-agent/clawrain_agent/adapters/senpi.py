"""Senpi MCP adapter — wraps mcporter calls."""
import subprocess
import json
from typing import Any, Dict, Optional


def mcporter_call(tool: str, **kwargs) -> Dict[str, Any]:
    """Call a Senpi MCP tool via mcporter CLI."""
    args = ["mcporter", "call", f"senpi.{tool}"]
    for k, v in kwargs.items():
        args.append(f"{k}={v}")

    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip() or f"mcporter exit code {result.returncode}"}
        return json.loads(result.stdout)
    except subprocess.TimeoutExpired:
        return {"error": "mcporter call timed out (30s)"}
    except json.JSONDecodeError:
        return {"error": "Invalid JSON from mcporter", "raw": result.stdout[:500]}
    except FileNotFoundError:
        return {"error": "mcporter not found — is it installed?"}


def get_positions(strategy_wallet: str) -> Dict[str, Any]:
    """Get open positions via Senpi clearinghouse state."""
    return mcporter_call("strategy_get_clearinghouse_state",
                         strategy_wallet=strategy_wallet)


def get_strategy(strategy_id: str) -> Dict[str, Any]:
    """Get strategy status and balance."""
    return mcporter_call("strategy_get", strategyId=strategy_id)


def get_open_orders(strategy_id: str) -> Dict[str, Any]:
    """Get open orders and stop losses."""
    return mcporter_call("strategy_get_open_orders", strategyId=strategy_id)
