// Soak (endurance) test — "is it still healthy after hours at normal load?"
//
// Constant VUS for DURATION (default 2h). Short tests cannot see slow failures:
//   - memory growth in PHP-FPM workers (pm.max_requests not set) or in APCu
//   - the sessions/cache tables growing (SESSION_DRIVER=database: GC lottery)
//   - disk filling with logs, MySQL binlogs, Docker json-file logs
//   - connection leaks, slow-query creep as tables grow (students created by k6)
// The check is that p95 and error rate in the LAST hour match the first hour —
// compare them in Grafana (the end-of-test summary averages them away).
//
//   k6 run -e BASE_URL=... -e VUS=20 -e DURATION=4h -e TEST_ID=soak-$(date +%F) loadtest/k6/soak.js
//
// Laravel sessions are sliding (SESSION_LIFETIME = idle minutes), so a busy VU keeps
// its session for hours. If one is lost anyway (session GC, Redis without
// persistence restarted, APP_KEY differing between replicas) the VU logs in again
// and session_relogins counts it — not a failure here, but a number to explain.

import { baseOptions, envInt, envStr, parseDuration, seconds, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, PAGE_NAMES } from './lib/journey.js';
import { think } from './lib/helpers.js';

export const options = baseOptions({
  scenarios: {
    soak: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '2m', target: envInt('VUS', 20) },
        { duration: seconds(parseDuration(envStr('DURATION', '2h'))), target: envInt('VUS', 20) },
        { duration: '2m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: Object.assign(sloThresholds({ allowRelogin: true }), showPerPage(PAGE_NAMES)),
});

export default function () {
  const s = ensureSession();
  if (!s) return;
  browse(s);
  think();
}
