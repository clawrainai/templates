// platform-push — Push agent metrics + FOX scan signals to Supabase
// Reads config.json for agent credentials
// No sensitive data (wallet seeds, API keys) ever leave the VPS
//
// Responsibilities:
// 1. Every 60s → push equity/pnl/win_rate to agent_metrics
// 2. On each FOX scan cycle → log signal to agent_signals
// 3. Track scanner + DSL cron health
// 4. Send Telegram on status changes / signals / errors

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');

const METRICS_INTERVAL_MS = 60_000;

// ─── Config ────────────────────────────────────────────────────────────────

function loadConfig() {
  const configPath = path.join(__dirname, '..', '..', 'config.json');
  try {
    return JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (e) {
    throw new Error(`platform-push: impossible de lire config.json: ${e.message}`);
  }
}

// ─── HTTP ──────────────────────────────────────────────────────────────────

function request(url, method, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const lib = urlObj.protocol === 'https:' ? https : http;
    const hdrs = {
      'Content-Type': 'application/json',
      'apikey': headers.apikey,
      'Authorization': `Bearer ${headers.authorization}`,
      ...headers,
    };
    delete hdrs.apikey;
    delete hdrs.authorization;

    const options = {
      hostname: urlObj.hostname,
      port: urlObj.port || (urlObj.protocol === 'https:' ? 443 : 80),
      path: urlObj.pathname + urlObj.search,
      method,
      headers: hdrs,
    };

    const req = lib.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
        catch { resolve({ status: res.statusCode, body }); }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ─── Supabase helpers ───────────────────────────────────────────────────────

async function pushMetrics(config, metrics) {
  const { agent_id, platform } = config;
  const url = `${platform.endpoint}/rest/v1/agent_metrics`;
  const res = await request(url, 'POST', {
    agent_id,
    equity: metrics.equity ?? null,
    pnl_total: metrics.pnl_total ?? null,
    win_rate: metrics.win_rate ?? null,
    total_trades: metrics.total_trades ?? 0,
    equity_curve: metrics.equity_curve ?? [],
    status: metrics.status ?? 'live',
  }, {
    authorization: platform.api_token,
    Prefer: 'return=minimal',
  });
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`metrics push failed: ${res.status}`);
  }
}

async function logSignal(config, signal) {
  const { agent_id, platform } = config;
  const url = `${platform.endpoint}/rest/v1/agent_signals`;
  const res = await request(url, 'POST', {
    agent_id,
    scanned_at: signal.scanned_at || new Date().toISOString(),
    mode: signal.mode || null,
    token: signal.token || null,
    direction: signal.direction || null,
    score: signal.score || null,
    reasons: signal.reasons || [],
    action: signal.action,
    block_reason: signal.block_reason || null,
    dsl_state: signal.dsl_state || null,
  }, {
    authorization: platform.api_token,
    Prefer: 'return=minimal',
  });
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`signal log failed: ${res.status}`);
  }
}

// ─── FOX Scanner ───────────────────────────────────────────────────────────

const FOX_SCAN_STATE_FILE = path.join(__dirname, '..', '..', 'state', 'last_scan.json');
const FOX_SCAN_HISTORY_FILE = path.join(__dirname, '..', '..', 'state', 'scan_history.json');

/**
 * Read the last FOX scanner output from the state file written by fox-scanner.py
 * Returns null if no scan has run yet.
 */
function readLastFoxScan() {
  try {
    if (fs.existsSync(FOX_SCAN_STATE_FILE)) {
      return JSON.parse(fs.readFileSync(FOX_SCAN_STATE_FILE, 'utf8'));
    }
  } catch {}
  return null;
}

/**
 * Determine what action a signal resulted in
 */
function determineAction(signal, openPositions) {
  if (!signal || !signal.hasSignal) return 'NO_SIGNAL';
  const top = signal.combined?.[0];
  if (!top) return 'NO_SIGNAL';

  const maxPositions = signal.constraints?.maxPositions || 3;
  if (openPositions >= maxPositions) {
    return 'SKIPPED_MAX_POSITIONS';
  }

  return 'SIGNAL_DETECTED';
}

/**
 * Parse a FOX scan result and extract the best signal for logging
 */
function parseFoxScan(scanResult, openPositions = 0) {
  if (!scanResult) {
    return { scanned_at: new Date().toISOString(), mode: null, token: null,
             direction: null, score: null, reasons: [], action: 'NO_SCAN', block_reason: null, dsl_state: null };
  }

  const top = scanResult.combined?.[0];
  const action = determineAction(scanResult, openPositions);

  let block_reason = null;
  if (action === 'SKIPPED_MAX_POSITIONS') {
    block_reason = `max positions (${openPositions}/3)`;
  } else if (scanResult.stalkerStreakActive && top?.mode === 'STALKER') {
    block_reason = 'streak_gate_active';
  }

  return {
    scanned_at: scanResult.time || new Date().toISOString(),
    mode: top?.mode || null,
    token: top?.token || null,
    direction: top?.direction || null,
    score: top?.score || null,
    reasons: top?.reasons || [],
    action,
    block_reason,
    dsl_state: top?.dslState || null,
  };
}

// ─── Metrics collection ─────────────────────────────────────────────────────

async function collectMetrics(ctx) {
  try {
    const equity = await ctx.call('senpi.getEquity', []);
    const positions = await ctx.call('senpi.getPositions', []);
    const trades = await ctx.call('senpi.getTrades', []);

    const pnl_total = positions.reduce((sum, p) => sum + (p.unrealized_pnl || 0), 0);
    const win_trades = trades.filter(t => t.pnl > 0).length;
    const win_rate = trades.length > 0 ? win_trades / trades.length : 0;

    const equity_curve = [];
    let running = 0;
    for (const trade of trades.slice(-100)) {
      running += trade.pnl || 0;
      equity_curve.push({ ts: trade.timestamp, value: running });
    }

    return {
      equity,
      pnl_total,
      win_rate,
      total_trades: trades.length,
      equity_curve,
      positions,
      open_positions: positions.length,
    };
  } catch {
    return ctx.state.metrics || { equity: 0, pnl_total: 0, win_rate: 0, total_trades: 0, equity_curve: [], open_positions: 0 };
  }
}

// ─── Telegram ───────────────────────────────────────────────────────────────

async function sendTelegram(config, message) {
  const { notifications } = config;
  if (!notifications?.bot_token || !notifications?.chat_id) return;

  const url = `https://api.telegram.org/bot${notifications.bot_token}/sendMessage`;
  const body = {
    chat_id: notifications.chat_id,
    text: `🤖 *${config.name || 'Agent'}*\n${message}`,
    parse_mode: 'Markdown',
  };
  if (notifications.thread_id) body.message_thread_id = notifications.thread_id;

  try {
    await request(url, 'POST', body, {});
  } catch {}
}

// ─── Cron health ─────────────────────────────────────────────────────────────

/**
 * Track scanner + DSL last run time and health.
 * ctx.state.cronHealth = { scanner: { lastAt, intervalMs }, dsl: { lastAt, intervalMs } }
 */
function checkCronHealth(ctx) {
  const now = Date.now();
  const health = ctx.state.cronHealth || { scanner: { lastAt: null, intervalMs: 90_000 }, dsl: { lastAt: null, intervalMs: 180_000 } };

  // scanner: fox-scanner.py runs every 90s
  // dsl: dsl-v5.py runs every 3min
  // If last run was > 2x interval ago → stale

  const scannerAge = health.scanner.lastAt ? (now - health.scanner.lastAt) : null;
  const dslAge = health.dsl.lastAt ? (now - health.dsl.lastAt) : null;

  const scannerOk = !scannerAge || scannerAge < health.scanner.intervalMs * 2;
  const dslOk = !dslAge || dslAge < health.dsl.intervalMs * 2;

  return {
    scanner: { lastAt: health.scanner.lastAt ? new Date(health.scanner.lastAt).toISOString() : null, ok: scannerOk, ageSec: scannerAge ? Math.round(scannerAge / 1000) : null },
    dsl: { lastAt: health.dsl.lastAt ? new Date(health.dsl.lastAt).toISOString() : null, ok: dslOk, ageSec: dslAge ? Math.round(dslAge / 1000) : null },
    stalkerStreak: false, // will be read from scan
  };
}

// ─── Module ─────────────────────────────────────────────────────────────────

module.exports = {
  name: 'platform-push',
  version: '2.0',
  market: 'hyperliquid',
  service: 'senpi',

  async onStart(ctx) {
    const config = loadConfig();
    ctx.state.config = config;
    ctx.state.lastStatus = config.status || 'paused';
    ctx.state.lastScanResult = null;
    ctx.state.cronHealth = { scanner: { lastAt: null, intervalMs: 90_000 }, dsl: { lastAt: null, intervalMs: 180_000 } };
    ctx.state.lastSignalAction = null;

    // Metrics push loop — every 60s
    ctx.state.pushInterval = setInterval(async () => {
      try {
        const metrics = await collectMetrics(ctx);
        await pushMetrics(config, metrics);
        ctx.state.metrics = metrics;

        // Cron health check
        const health = checkCronHealth(ctx);
        if (!health.scanner.ok) {
          await sendTelegram(config, `⚠️ *Scanner stale*\nLast run: ${health.scanner.ageSec}s ago`);
        }
        if (!health.dsl.ok) {
          await sendTelegram(config, `⚠️ *DSL stale*\nLast run: ${health.dsl.ageSec}s ago`);
        }

        // Status change notification
        if (metrics.status && metrics.status !== ctx.state.lastStatus) {
          await sendTelegram(config, `📊 Status: *${ctx.state.lastStatus}* → *${metrics.status}*`);
          ctx.state.lastStatus = metrics.status;
        }
      } catch (err) {
        console.error('[platform-push] push error:', err.message);
        await sendTelegram(config, `⚠️ Push error: \`${err.message}\``);
      }
    }, METRICS_INTERVAL_MS);

    console.log('[platform-push] v2.0 started — metrics every 60s');
  },

  /**
   * Called by OpenClaw after each FOX scan cycle (every 90s when fox-scanner.py runs)
   * Reads the scan result from state file and logs to Supabase
   */
  async onCycle(ctx) {
    try {
      const scanResult = readLastFoxScan();
      const metrics = ctx.state.metrics || {};
      const openPositions = metrics.open_positions || 0;
      const signal = parseFoxScan(scanResult, openPositions);

      // Update cron health
      if (ctx.state.cronHealth) {
        ctx.state.cronHealth.scanner.lastAt = Date.now();
      }

      // Log signal to Supabase (even NO_SCAN to prove liveness)
      await logSignal(config, signal);

      // Store for dashboard queries
      ctx.state.lastScanResult = { ...signal, scanResult };

      // Signal notifications
      if (signal.action === 'SIGNAL_DETECTED') {
        const emoji = signal.direction === 'LONG' ? '🟢' : '🔴';
        const reasonsStr = signal.reasons.slice(0, 3).join(', ');
        await sendTelegram(config,
          `${emoji} *${signal.mode} SIGNAL*\n` +
          `*${signal.token}/${signal.direction}* score:${signal.score}\n` +
          `_${reasonsStr}_`
        );
        ctx.state.lastSignalAction = signal.action;
      } else if (signal.action === 'SKIPPED_MAX_POSITIONS') {
        if (ctx.state.lastSignalAction !== 'SKIPPED_MAX_POSITIONS') {
          await sendTelegram(config, `⏭️ ${signal.token} signal blocked — max positions (${openPositions}/3)`);
          ctx.state.lastSignalAction = signal.action;
        }
      }

    } catch (err) {
      console.error('[platform-push] onCycle error:', err.message);
    }
  },

  /**
   * Called when DSL cron fires (every 3min per position)
   */
  async onDslCycle(ctx, dslState) {
    try {
      if (!dslState) return;
      const config = ctx.state.config;

      // Log tier changes or pending closes
      if (dslState.pending_close) {
        await sendTelegram(config, `🚨 *DSL Close pending*\n${dslState.asset} — ${dslState.direction}`);
      }
      if (dslState.tier_changed) {
        await sendTelegram(config, `📊 *DSL Tier hit*\n${dslState.asset} — Tier ${dslState.currentTierIndex+1} locked`);
      }

      // Update DSL cron health
      if (ctx.state.cronHealth) {
        ctx.state.cronHealth.dsl.lastAt = Date.now();
      }
    } catch (err) {
      console.error('[platform-push] dslCycle error:', err.message);
    }
  },

  async onStop(ctx) {
    if (ctx.state.pushInterval) clearInterval(ctx.state.pushInterval);
    console.log('[platform-push] stopped');
  },
};
