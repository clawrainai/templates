"""Historical data endpoints — from SQLite."""
from typing import Dict, Any, Optional
from ..db import MetricsDB


def fetch_pnl_history(db: MetricsDB) -> Dict[str, Any]:
    """Get PnL history for LineChart widget.
    
    Returns LineChart-compatible format:
    { labels: [...], datasets: [{ label, data }] }
    """
    snapshots = db.get_snapshots(limit=90)
    snapshots.reverse()  # Oldest first for chart

    return {
        "labels": [s["date"] for s in snapshots],
        "datasets": [
            {
                "label": "Balance",
                "data": [s["balance"] for s in snapshots],
            },
            {
                "label": "Daily PnL",
                "data": [s["pnl_day"] for s in snapshots],
            },
        ],
    }


def fetch_trades(db: MetricsDB) -> Dict[str, Any]:
    """Get trade history for DataTable widget.
    
    Returns DataTable-compatible format:
    { columns: [...], rows: [...] }
    """
    columns = [
        {"key": "asset", "label": "Asset"},
        {"key": "direction", "label": "Side"},
        {"key": "pnl", "label": "PnL"},
        {"key": "entry_price", "label": "Entry"},
        {"key": "exit_price", "label": "Exit"},
        {"key": "leverage", "label": "Lev"},
        {"key": "duration_min", "label": "Duration"},
        {"key": "exit_reason", "label": "Reason"},
        {"key": "closed_at", "label": "Closed"},
    ]

    trades = db.get_trades(limit=50)
    rows = []
    for t in trades:
        rows.append({
            "asset": t["asset"],
            "direction": t["direction"],
            "pnl": f"${t['pnl']:+.2f}" if t["pnl"] is not None else "—",
            "entry_price": f"{t['entry_price']:.4f}" if t["entry_price"] else "—",
            "exit_price": f"{t['exit_price']:.4f}" if t["exit_price"] else "—",
            "leverage": f"{t['leverage']:.0f}x" if t["leverage"] else "—",
            "duration_min": f"{t['duration_min']}m" if t["duration_min"] else "—",
            "exit_reason": t["exit_reason"] or "—",
            "closed_at": t["closed_at"] or "—",
        })

    return {"columns": columns, "rows": rows}
