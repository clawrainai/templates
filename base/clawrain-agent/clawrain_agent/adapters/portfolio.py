"""Portfolio endpoint — realtime from Senpi."""
from typing import Dict, Any, List
from .senpi import get_strategy


def fetch_portfolio(strategies: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Fetch portfolio summary for all strategies.
    
    Returns MetricCard-compatible format:
    { metrics: [{ label, value, change }] }
    """
    total_balance = 0.0
    total_pnl = 0.0
    total_budget = 0.0
    active_count = 0

    for strat in strategies:
        sid = strat.get("strategyId", "")
        budget = float(strat.get("budget", 0))
        total_budget += budget

        if not sid:
            continue

        data = get_strategy(sid)
        if "error" in data:
            continue

        balance = float(data.get("balance", budget))
        pnl = balance - budget
        total_balance += balance
        total_pnl += pnl
        active_count += 1

    pnl_pct = (total_pnl / total_budget * 100) if total_budget > 0 else 0
    drawdown = min(0, total_pnl)

    return {
        "metrics": [
            {"label": "Balance", "value": f"${total_balance:,.2f}", "change": None},
            {"label": "PnL", "value": f"${total_pnl:+,.2f}", "change": f"{pnl_pct:+.1f}%"},
            {"label": "Budget", "value": f"${total_budget:,.2f}", "change": None},
            {"label": "Strategies", "value": str(active_count), "change": None},
        ]
    }
