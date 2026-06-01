'use strict';
/**
 * TechStream — Buggy Web Server (Node.js / Express)
 * Simulates a real application with endpoints that can be made to misbehave
 * for chaos testing purposes.
 *
 * Install: npm install express
 * Run:     node app.js
 */

const express = require('express');
const os      = require('os');

const app = express();
app.use(express.json());

// ── Chaos state ───────────────────────────────────────────────────────────────
let chaosMode    = false;
let errorRate    = 0.0;   // 0.0–1.0  (0.6 = 60% of requests fail)
let latencyMs    = 0;     // extra ms added to every response
let requestCount = 0;

app.use((_req, _res, next) => { requestCount++; next(); });

// ── Chaos middleware ──────────────────────────────────────────────────────────
function injectChaos(_req, res, next) {
  if (!chaosMode) return next();
  const proceed = () => {
    if (Math.random() < errorRate) {
      console.error('Chaos: injecting HTTP 500');
      return res.status(500).json({ error: 'chaos injected' });
    }
    next();
  };
  latencyMs > 0 ? setTimeout(proceed, latencyMs) : proceed();
}

// ── CPU percent snapshot ──────────────────────────────────────────────────────
function cpuPercent() {
  let totalIdle = 0, totalTick = 0;
  for (const cpu of os.cpus()) {
    for (const val of Object.values(cpu.times)) totalTick += val;
    totalIdle += cpu.times.idle;
  }
  return Math.round((1 - totalIdle / totalTick) * 100);
}

// ── Golden Signal endpoints ───────────────────────────────────────────────────

app.get('/', injectChaos, (_req, res) => {
  res.json({ status: 'ok', service: 'techstream-api' });
});

app.get('/api/data', injectChaos, (_req, res) => {
  const delay = 50 + Math.random() * 100;   // normal DB latency 50–150 ms
  setTimeout(() => {
    res.json({ records: Array.from({ length: 10 }, (_, i) => ({ id: i, value: Math.random() })) });
  }, delay);
});

app.get('/api/heavy', injectChaos, (_req, res) => {
  let result = 0;
  for (let i = 0; i < 1_000_000; i++) result += i * i;   // simulate CPU work
  res.json({ result });
});

app.get('/health', (_req, res) => {
  res.json({
    status:          'healthy',
    cpu_percent:     cpuPercent(),
    memory_percent:  Math.round((1 - os.freemem() / os.totalmem()) * 100),
    request_count:   requestCount,
    chaos_mode:      chaosMode,
    error_rate:      errorRate,
  });
});

app.get('/metrics', (_req, res) => {
  const cpu = cpuPercent();
  const mem = Math.round((1 - os.freemem() / os.totalmem()) * 100);
  res.type('text/plain').send([
    '# HELP http_requests_total Total HTTP requests',
    '# TYPE http_requests_total counter',
    `http_requests_total ${requestCount}`,
    '# HELP process_cpu_percent CPU utilization percent',
    '# TYPE process_cpu_percent gauge',
    `process_cpu_percent ${cpu}`,
    '# HELP process_memory_percent Memory utilization percent',
    '# TYPE process_memory_percent gauge',
    `process_memory_percent ${mem}`,
    '# HELP chaos_mode_active Whether chaos mode is on',
    '# TYPE chaos_mode_active gauge',
    `chaos_mode_active ${chaosMode ? 1 : 0}`,
  ].join('\n'));
});

// ── Chaos control endpoints ───────────────────────────────────────────────────

app.post('/chaos/enable', (req, res) => {
  const body   = req.body || {};
  chaosMode    = true;
  errorRate    = parseFloat(body.error_rate  ?? 0.6);
  latencyMs    = parseInt(body.latency_ms    ?? 500, 10);
  console.warn(`CHAOS ENABLED — error_rate=${errorRate}, latency_ms=${latencyMs}`);
  res.json({ chaos: 'enabled', error_rate: errorRate, latency_ms: latencyMs });
});

app.post('/chaos/disable', (_req, res) => {
  chaosMode = false;
  errorRate = 0.0;
  latencyMs = 0;
  console.info('Chaos mode disabled — returning to normal operation');
  res.json({ chaos: 'disabled' });
});

const PORT = parseInt(process.env.PORT || '5000', 10);
app.listen(PORT, '0.0.0.0', () =>
  console.info(`TechStream listening on http://0.0.0.0:${PORT}`)
);
