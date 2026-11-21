// Spike test — "what happens when traffic jumps 10x in seconds (a WhatsApp
// broadcast, a marketing push), and how fast do we recover?"
//
//   baseline VUS ──► SPIKE_VUS in 10s ──► hold DURATION ──► back to VUS ──► 2m recovery
//
// Things to watch: errors during the first seconds (no warm capacity, autoscaling
// is minutes behind a spike — only headroom saves you), PHP-FPM "max_children
// reached", MySQL connections, and whether latency returns to baseline in the
// recovery window. 10x a small baseline also means 10x fresh logins (bcrypt).
//
//   k6 run -e BASE_URL=... -e VUS=5 -e SPIKE_VUS=100 -e DURATION=1m loadtest/k6/spike.js

import { baseOptions, envInt, envStr, parseDuration, seconds, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { browse, PAGE_NAMES } from './lib/journey.js';
import { think } from './lib/helpers.js';

const VUS = envInt('VUS', 5);
const SPIKE_VUS = envInt('SPIKE_VUS', VUS * 10);
const HOLD = parseDuration(envStr('DURATION', '1m'));

export const options = baseOptions({
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: VUS }, // baseline
        { duration: '1m', target: VUS },
        { duration: '10s', target: SPIKE_VUS }, // the spike
        { duration: seconds(HOLD), target: SPIKE_VUS },
        { duration: '10s', target: VUS }, // drop
        { duration: '2m', target: VUS }, // recovery window
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  // Same SLOs: a spike that burns the error budget is a real incident for users.
  thresholds: Object.assign(sloThresholds(), showPerPage(PAGE_NAMES)),
});

export default function () {
  const s = ensureSession();
  if (!s) return;
  browse(s);
  think();
}
