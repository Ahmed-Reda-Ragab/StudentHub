// Load test — "does the service meet its SLOs at the traffic we expect?" (scenarios 73/74)
//
// Ramps to VUS virtual users (20% of DURATION), holds (60%), ramps down (20%).
// Every VU logs in once and then browses with think time: a realistic,
// read-heavy mix (see lib/journey.js). Thresholds are the SLOs, so a breach
// fails the run (exit code 99) and therefore the pipeline.
//
//   k6 run -e BASE_URL=http://localhost:8080 -e LOADTEST_USERS=5 -e VUS=5 -e DURATION=45s loadtest/k6/load.js
//   k6 run -e BASE_URL=https://lab.example.com -e VUS=50 -e DURATION=10m -e P95_MS=300 loadtest/k6/load.js
//
// Rough sizing: each VU makes ~1 request / THINK_TIME seconds, so VUS=50 with
// THINK_TIME=1 is ~40-50 req/s (Little's law: throughput = users / (think + response time)).

import { baseOptions, envInt, envStr, parseDuration, seconds, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, PAGE_NAMES } from './lib/journey.js';
import { think } from './lib/helpers.js';

const VUS = envInt('VUS', 10);
const TOTAL = parseDuration(envStr('DURATION', '5m'));
const RAMP = Math.max(1, Math.round(TOTAL * 0.2));
const HOLD = Math.max(1, Math.round(TOTAL - 2 * RAMP));

export const options = baseOptions({
  scenarios: {
    load: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: seconds(RAMP), target: VUS }, // warm-up: opcache, DB buffer pool, connection pools
        { duration: seconds(HOLD), target: VUS }, // steady state: this is what the SLO is judged on
        { duration: seconds(RAMP), target: 0 },
      ],
      gracefulRampDown: '15s',
      gracefulStop: '15s',
    },
  },
  thresholds: Object.assign(sloThresholds(), showPerPage(PAGE_NAMES)),
});

export default function () {
  const s = ensureSession();
  if (!s) return;
  browse(s);
  think();
}
