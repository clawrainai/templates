"""Positions endpoint — realtime from Senpi."""
from typing import Dict, Any, List
from .senpi import get_positions


def fetch_positions(strategies: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Fetch open positions for all strategies.
    
    Returns DataTable-compatible format:
    { columns: [...], rows: [...] }
    """
    columns = [
        {"key": "asset", "label": "Asset"},
        {"key": "direction", "label": "Side"},
        {"key": "size", "label": "Size"},
        {"key": "entry_price", "label": "Entry"},
        {"key": "mark_price", "label": "Mark"},
        {"key": "pnl", "label": "PnL"},
        {"key": "leverage", "label": "Lev"},
        {"key": "strategy", "label": "Strategy"},
    ]
    rows = []

    for strat in strategies:
        wallet = strat.get("wallet", "")
        name = strat.get("name", strat.get("_key", "unknown"))
        if not wallet:
            continue

        data = get_positions(wallet)
        if "error" in data:
            continue

        # Parse clearinghouse state
        positions = data.get("assetPositions", [])
        for pos in positions:
            p = pos.get("position", {})
            if not p:
                continue
            entry = float(p.get("entryPx", 0))
            size = float(p.get("szi", 0))
            pnl = float(p.get("unrealizedPnl", 0))
            leverage = float(p.get("leverage", {}).get("value", 0))
            rows.append({
                "asset": p.get("coin", "?"),
                "direction": "LONG" if size > 0 else "SHORT",
                "size": abs(size),
                "entry_price": entry,
                "mark_price": float(p.get("markPx", entry)),
                "pnl": round(pnl, 2),
                "leverage": f"{leverage:.0f}x",
                "strategy": name,
            })

    return {"columns": columns, "rows": rows}
