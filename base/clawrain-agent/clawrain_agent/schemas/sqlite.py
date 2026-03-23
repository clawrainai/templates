"""SQLite schema for historical metrics."""

SCHEMA_SQL = """
-- Daily portfolio snapshots (cron daily)
CREATE TABLE IF NOT EXISTS daily_snapshots (
    date         TEXT PRIMARY KEY,
    balance      REAL,
    pnl_day      REAL,
    pnl_total    REAL,
    positions    INTEGER,
    trades_count INTEGER,
    drawdown     REAL,
    created_at   TEXT DEFAULT (datetime('now'))
);

-- Closed trades log
CREATE TABLE IF NOT EXISTS trades (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    asset        TEXT NOT NULL,
    direction    TEXT NOT NULL,
    entry_price  REAL,
    exit_price   REAL,
    size         REAL,
    leverage     REAL,
    pnl          REAL,
    fees         REAL,
    duration_min INTEGER,
    score        INTEGER,
    opened_at    TEXT,
    closed_at    TEXT,
    strategy_key TEXT,
    exit_reason  TEXT
);

-- Scanner signals log
CREATE TABLE IF NOT EXISTS signals (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    asset        TEXT NOT NULL,
    signal_type  TEXT,
    score        INTEGER,
    acted_on     BOOLEAN DEFAULT 0,
    reason       TEXT,
    timestamp    TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_trades_closed ON trades(closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_signals_ts ON signals(timestamp DESC);
"""
