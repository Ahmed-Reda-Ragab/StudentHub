// Breakpoint (capacity) test — "how many requests per second can this setup serve
// inside the SLO?" The answer is the number you size autoscaling and alarms with.
//
// Open model: ramping-arrival-rate starts START_RATE iterations/s and climbs
// linearly to MAX_RATE over DURATION. Unlike VU-based tests, k6 keeps sending at
// the target rate even when the server slows down (that is how real traffic
// behaves — users do not wait for each other), so the knee shows up clearly.
// One iteration = one page view (no think time; the rate IS the pacing).
//
// Thresholds abort the run once the SLO is clearly gone (abortOnFail). k6
// thresholds are evaluated on the WHOLE run so far, so the abort lags the real
// knee a little: read the exact point from Grafana / the web dashboard
// (http_reqs rate vs p95). dropped_iterations > 0 means k6 ran out of VUs
// (Little's law: VUs needed = rate × response time) — the server is too slow.
//
//   k6 run -e BASE_URL=... -e START_RATE=5 -e MAX_RATE=300 -e DURATION=20m loadtest/k6/breakpoint.js
//   k6 run -e BASE_URL=... -e TARGET=ping loadtest/k6/breakpoint.js      # PHP-FPM ceiling, no DB
//   k6 run -e BASE_URL=... -e TARGET=db-heavy loadtest/k6/breakpoint.js  # the database ceiling
//
// Never point this at an environment shared with real users.

import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, baseOptions, envInt, envStr, parseDuration, seconds, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, PAGE_NAMES } from './lib/journey.js';
import { labParams } from './lib/helpers.js';

const TARGET = envStr('TARGET', 'journey'); // journey | ping | db | db-heavy | cpu
const START_RATE = envInt('START_RATE', 5);
const MAX_RATE = envInt('MAX_RATE', 200);
const DURATION = parseDuration(envStr('DURATION', '20m'));
const CPU_MS = envInt('CPU_MS', 50);

const LAB_TARGETS = {
  ping: { path: '/sre-lab/ping', name: 'sre-lab.ping' },
  db: { path: '/sre-lab/db?limit=50', name: 'sre-lab.db' },
  'db-heavy': { path: '/sre-lab/db/heavy', name: 'sre-lab.db.heavy' },
  cpu: { path: `/sre-lab/cpu?ms=${CPU_MS}`, name: 'sre-lab.cpu' },
};
if (TARGET !== 'journey' && !LAB_TARGETS[TARGET]) {
  throw new Error(`TARGET must be journey, ${Object.keys(LAB_TARGETS).join(', ')} (got "${TARGET}")`);
}

export const options = baseOptions({
  scenarios: {
    breakpoint: {
      executor: 'ramping-arrival-rate',
      startRate: START_RATE,
      timeUnit: '1s',
      preAllocatedVUs: envInt('PRE_VUS', 50),
      maxVUs: envInt('MAX_VUS', 1000),
      stages: [{ duration: seconds(DURATION), target: MAX_RATE }],
    },
  },
  thresholds: Object.assign(
    sloThresholds({ abortOnFail: true, delayAbortEval: '30s' }),
    { dropped_iterations: [{ threshold: `count<${envInt('MAX_DROPPED', 100)}`, abortOnFail: true }] },
    showPerPage(TARGET === 'journey' ? PAGE_NAMES : [LAB_TARGETS[TARGET].name]),
  ),
});

export default function () {
  if (TARGET === 'journey') {
    const s = ensureSession();
    if (s) browse(s);
    return;
  }
  const t = LAB_TARGETS[TARGET];
  const res = http.get(`${BASE_URL}${t.path}`, labParams(t.name));
  check(res, { [`${t.name}: 200`]: (r) => r.status === 200 });
}
