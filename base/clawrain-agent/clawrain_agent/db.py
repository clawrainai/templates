"""SQLite database manager for historical metrics."""
import sqlite3
import os
from typing import List, Dict, Any, Optional
from .schemas.sqlite import SCHEMA_SQL


class MetricsDB:
    def __init__(self, db_path: str):
        self.db_path = db_path
        os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
        self._init_schema()

    def _init_schema(self):
        with sqlite3.connect(self.db_path) as conn:
            conn.executescript(SCHEMA_SQL)

    def _query(self, sql: str, params: tuple = ()) -> List[Dict[str, Any]]:
        with sqlite3.connect(self.db_path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(sql, params).fetchall()
            return [dict(row) for row in rows]

    def _execute(self, sql: str, params: tuple = ()):
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(sql, params)
            conn.commit()

    # ─── Snapshots ────────────────────────────────────────────

    def insert_snapshot(self, date: str, balance: float, pnl_day: float,
                        pnl_total: float, positions: int, trades_count: int,
                        drawdown: float):
        self._execute(
            """INSERT OR REPLACE INTO daily_snapshots
               (date, balance, pnl_day, pnl_total, positions, trades_count, drawdown)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (date, balance, pnl_day, pnl_total, positions, trades_count, drawdown)
        )

    def get_snapshots(self, limit: int = 90) -> List[Dict[str, Any]]:
        return self._query(
            "SELECT * FROM daily_snapshots ORDER BY date DESC LIMIT ?", (limit,)
        )

    def get_latest_snapshot(self) -> Optional[Dict[str, Any]]:
        rows = self._query("SELECT * FROM daily_snapshots ORDER BY date DESC LIMIT 1")
        return rows[0] if rows else None

    # ─── Trades ───────────────────────────────────────────────

    def insert_trade(self, **kwargs):
        cols = ", ".join(kwargs.keys())
        placeholders = ", ".join(["?"] * len(kwargs))
        self._execute(
            f"INSERT INTO trades ({cols}) VALUES ({placeholders})",
            tuple(kwargs.values())
        )

    def get_trades(self, limit: int = 50) -> List[Dict[str, Any]]:
        return self._query(
            "SELECT * FROM trades ORDER BY closed_at DESC LIMIT ?", (limit,)
        )

    # ─── Signals ──────────────────────────────────────────────

    def insert_signal(self, asset: str, signal_type: str, score: int,
                      acted_on: bool = False, reason: str = ""):
        self._execute(
            """INSERT INTO signals (asset, signal_type, score, acted_on, reason)
               VALUES (?, ?, ?, ?, ?)""",
            (asset, signal_type, score, acted_on, reason)
        )

    def get_signals(self, limit: int = 50) -> List[Dict[str, Any]]:
        return self._query(
            "SELECT * FROM signals ORDER BY timestamp DESC LIMIT ?", (limit,)
        )
