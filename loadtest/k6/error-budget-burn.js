// Error-budget burn drill — "do the multi-window burn-rate alerts fire when they
// should, and how long does detection take?" (scenarios 73/76)
//
// ── The math ────────────────────────────────────────────────────────────────
// SLO = 99.5% of requests succeed over 30 days → error budget = 0.5% (0.005).
// Burn rate B = observed error ratio / error budget.
//   B = 1     → the budget lasts exactly 30 days            (error ratio 0.5%)
//   B = 6     → 5% of the monthly budget gone in 6 h         (error ratio 3%)
//   B = 14.4  → 2% of the monthly budget gone in 1 h         (error ratio 7.2%)
//              (14.4 = 0.02 × 720 h / 1 h; budget empty in 30 d / 14.4 ≈ 50 h)
// So to drive burn rate B we need an error ratio of B × 0.005:
//   /sre-lab/error?rate=<B × 0.005>
//
// Alerts (observability/prometheus/rules/slo-burn-rate.yml, CONVENTIONS §5):
//   page   : B > 14.4 over 1h AND 5m      page   : B > 6 over 6h AND 30m
//   ticket : B > 1    over 3d AND 6h
// Pick B a bit ABOVE the threshold you want to trip (random noise around exactly
// 14.4 makes the alert flap): default 20 → 10% errors → fast + slow page fire.
// BURN_RATE=8 → only the 6× page;  BURN_RATE=2 → only the ticket.
//
// Detection time: with steady traffic and a clean history, the long window's
// ratio after t minutes of burning is ratio × t / window, so the 1h/14.4× alert
// needs t ≈ 60 × 14.4 / B minutes (B=20 → ~43 min; a total outage B=200 → ~4 min).
// That trade-off (fast for big fires, slow for embers) is the point of
// multi-window alerts. Use WARMUP to send clean traffic first and see it for real.
//
// ── Two modes ───────────────────────────────────────────────────────────────
// MODE=lab (default): traffic to /sre-lab/error. Lab routes are EXCLUDED from the
//   real availability SLI, so this drives the separate "availability-drill" SLI
//   (route="sre-lab.error") and its *Drill* alerts, labelled drill="true" and
//   routed away from the real pager. Safe to run any time.
// MODE=app: realistic user traffic on real pages; you set the error ratio on the
//   server with the bad-release fault: SRE_FAULT_ERROR_RATE=<B × 0.005>
//   (CONVENTIONS §3). This burns the REAL availability SLO and fires the real pages.
//
//   k6 run -e BASE_URL=... -e BURN_RATE=20 -e RATE=10 -e DURATION=30m loadtest/k6/error-budget-burn.js
//   k6 run -e BASE_URL=... -e BURN_RATE=20 -e WARMUP=1h -e DURATION=1h loadtest/k6/error-budget-burn.js
//   SRE_FAULT_ERROR_RATE=0.1 docker compose up -d app   # then:
//   k6 run -e BASE_URL=... -e MODE=app -e BURN_RATE=20 -e DURATION=30m loadtest/k6/error-budget-burn.js
//
// Thresholds here only DISPLAY numbers: errors are the goal of this test.

import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE_URL, ERROR_BUDGET, baseOptions, envFloat, envInt, envStr, parseDuration, seconds } from './lib/config.js';
import { labParams, safeJson } from './lib/helpers.js';
import { ensureSession } from './lib/auth.js';
import { browse } from './lib/journey.js';

const MODE = envStr('MODE', 'lab');
const BURN_RATE = envFloat('BURN_RATE', 20);
const RATE = envInt('RATE', 10);
const DURATION = parseDuration(envStr('DURATION', '15m'));
const WARMUP = parseDuration(envStr('WARMUP', '0s'));
const CODE = envInt('CODE', 500);
const ERROR_RATIO = Math.min(1, Math.round(BURN_RATE * ERROR_BUDGET * 10000) / 10000);

if (MODE !== 'lab' && MODE !== 'app') throw new Error(`MODE must be lab or app (got "${MODE}")`);

const injected = new Counter('injected_errors');

function arrival(exec, duration, startTime) {
  return {
    executor: 'constant-arrival-rate',
    exec,
    rate: RATE,
    timeUnit: '1s',
    duration: seconds(duration),
    startTime: startTime > 0 ? seconds(startTime) : '0s',
    preAllocatedVUs: Math.max(5, RATE),
    maxVUs: Math.max(50, RATE * 5),
  };
}

const scenarios = {};
if (WARMUP > 0) scenarios.warmup = arrival(MODE === 'lab' ? 'healthy' : 'appTraffic', WARMUP, 0);
scenarios.burn = arrival(MODE === 'lab' ? 'burn' : 'appTraffic', DURATION, WARMUP);

export const options = baseOptions({
  scenarios,
  thresholds: {
    http_req_failed: ['rate>=0'], // display: should converge to ERROR_RATIO
    'http_req_failed{scenario:burn}': ['rate>=0'],
    injected_errors: ['count>=0'],
  },
});

export function setup() {
  console.log(
    `burn rate ${BURN_RATE}x of a ${ERROR_BUDGET * 100}% budget → target error ratio ${(ERROR_RATIO * 100).toFixed(2)}% ` +
      `at ${RATE} req/s for ${seconds(DURATION)} (warm-up: ${WARMUP > 0 ? seconds(WARMUP) : 'none'})`,
  );
  if (MODE === 'app') {
    console.log(`MODE=app: the app must run with SRE_FAULT_ERROR_RATE=${ERROR_RATIO} (and SRE_LAB_ENABLED=true)`);
  }
}

// Clean history before the incident (MODE=lab): same route, rate=0 → never fails.
export function healthy() {
  const res = http.get(`${BASE_URL}/sre-lab/error?rate=0`, labParams('sre-lab.error'));
  check(res, { 'warm-up: 200': (r) => r.status === 200 });
}

export function burn() {
  const res = http.get(`${BASE_URL}/sre-lab/error?rate=${ERROR_RATIO}&code=${CODE}`, labParams('sre-lab.error'));
  const body = safeJson(res) || {};
  if (res.status === CODE && body.injected === true) injected.add(1);
  // A 403/404 here means the lab is disabled or LAB_TOKEN is wrong — the drill is not running.
  check(res, { 'lab endpoint reachable (200 or injected error)': (r) => r.status === 200 || body.injected === true });
}

// MODE=app: one page view per iteration; the server decides which ones fail.
export function appTraffic() {
  const s = ensureSession();
  if (s) browse(s);
}
