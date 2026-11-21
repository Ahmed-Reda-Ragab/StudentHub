// Smoke test — "is this deployment basically working?" (scenarios 73/74)
//
// 2 VUs for ~30s: health endpoints, the SRE lab baseline, a real login, the
// read journey and ONE student creation per VU (proves CSRF + idempotency token +
// DB writes). Run it after every deploy, before any heavier test.
//
//   k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 loadtest/k6/smoke.js
//
// Zero-tolerance by design: any failed check or error fails the run.

import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, LAB_ENDPOINTS, P95_MS, baseOptions, envInt, envStr, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, createStudent, PAGE_NAMES } from './lib/journey.js';
import { PAGE_HEADERS, labParams, safeJson, think } from './lib/helpers.js';

export const options = baseOptions({
  scenarios: {
    smoke: {
      executor: 'constant-vus',
      vus: Math.min(envInt('VUS', 2), 2),
      duration: envStr('DURATION', '30s'),
      gracefulStop: '10s',
    },
  },
  // p99 is not gated here: 2 VUs make "p99" the single slowest request (a bcrypt login).
  thresholds: Object.assign(
    sloThresholds({ p95: P95_MS, p99: null, checks: 'rate==1' }),
    showPerPage(PAGE_NAMES.concat(['up', 'health.ready', 'sre-lab.ping'])),
  ),
});

let wroteOnce = false; // per VU

export default function () {
  platformChecks();

  const s = ensureSession();
  if (!s) return;

  if (!wroteOnce) {
    wroteOnce = true;
    createStudent(s);
    think();
  }

  browse(s);
  think();
}

function platformChecks() {
  // Liveness: process is up (no DB). Laravel's built-in /up returns an HTML page.
  const up = http.get(`${BASE_URL}/up`, { headers: PAGE_HEADERS, tags: { name: 'up' } });
  check(up, { 'up: 200': (r) => r.status === 200 });

  // Readiness: DB reachable, and tells us which release answered.
  const ready = http.get(`${BASE_URL}/ready`, { headers: { Accept: 'application/json' }, tags: { name: 'health.ready' } });
  const body = safeJson(ready) || {};
  check(ready, {
    'ready: 200': (r) => r.status === 200,
    'ready: status=ready, db ok': () => body.status === 'ready' && body.checks && body.checks.database === 'ok',
    'ready: reports version + color': () => typeof body.version === 'string' && typeof body.color === 'string',
  });

  if (LAB_ENDPOINTS) {
    // 403 here = the app has SRE_LAB_TOKEN set and you did not pass -e LAB_TOKEN=...
    const ping = http.get(`${BASE_URL}/sre-lab/ping`, labParams('sre-lab.ping'));
    check(ping, { 'sre-lab ping: 200 ok': (r) => r.status === 200 && (safeJson(r) || {}).status === 'ok' });
  }
}
