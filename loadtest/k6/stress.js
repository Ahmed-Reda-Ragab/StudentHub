// Stress test — "what breaks first above normal load, and does it degrade gracefully?"
//
// Steps of 1x, 2x, 3x, 4x the normal load (VUS), each held for DURATION, then a
// ramp down to watch recovery. A red result is EXPECTED somewhere up the ladder;
// the questions are *at which step* the SLO broke, *what* saturated first
// (PHP-FPM workers? MySQL CPU? connections?) and whether errors were clean 5xx/503
// or timeouts. Watch Grafana (RED + node/cAdvisor) while it runs.
//
//   k6 run -e BASE_URL=... -e VUS=20 -e DURATION=2m loadtest/k6/stress.js
//   k6 run -e BASE_URL=... -e VUS=20 -e STEPS=1,2,4,8 loadtest/k6/stress.js
//
// Not meant for CI: it is supposed to push the system past its limits.

import { baseOptions, envInt, envList, envStr, parseDuration, seconds, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, PAGE_NAMES } from './lib/journey.js';
import { think } from './lib/helpers.js';

const VUS = envInt('VUS', 20);
const HOLD = parseDuration(envStr('DURATION', '2m'));
const STEPS = envList('STEPS', ['1', '2', '3', '4']).map(Number);

const stages = [];
STEPS.forEach((m) => {
  stages.push({ duration: '30s', target: Math.round(VUS * m) });
  stages.push({ duration: seconds(HOLD), target: Math.round(VUS * m) });
});
stages.push({ duration: '1m', target: 0 }); // recovery: latency must come back down on its own

export const options = baseOptions({
  scenarios: {
    stress: { executor: 'ramping-vus', startVUs: 1, stages, gracefulRampDown: '30s' },
  },
  thresholds: Object.assign(sloThresholds(), showPerPage(PAGE_NAMES)),
});

export default function () {
  const s = ensureSession();
  if (!s) return;
  browse(s);
  think();
}
