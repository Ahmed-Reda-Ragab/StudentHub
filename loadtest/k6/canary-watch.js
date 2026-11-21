// Canary / blue-green watcher — "which release is answering, in what proportion,
// and did ANY request fail while traffic moved?" Run it during a deploy.
//
// Sends RATE req/s to /ready (no session, no DB writes; it reports
// {"version","color"}) and counts responses per release. Each iteration is a
// brand-new client (cookies reset between iterations), so a sticky A/B cookie
// never pins a VU to one colour and weighted splits show up as they really are.
//
// What you get in the end-of-test summary:
//   release_responses{color:blue|green|canary|stable|none}   → the traffic split
//   release_responses{version:<v>}                         → per version (EXPECT_VERSIONS=v1,v2)
//   release_latency / release_errors per colour            → a mini canary analysis
//   canary_share                                           → % of requests the canary got
//   http_req_failed                                        → must stay ~0: that is "zero downtime"
// With --out experimental-prometheus-rw (or opentelemetry) the version/color tags
// become labels, so Grafana shows the split live while weights change.
//
//   k6 run -e BASE_URL=http://<lb> -e DURATION=3m loadtest/k6/canary-watch.js
//   k6 run -e BASE_URL=http://<lb> -e CANARY_COLOR=green -e EXPECT_CANARY_PCT=25 -e TOLERANCE_PCT=5 loadtest/k6/canary-watch.js
//   k6 run -e BASE_URL=http://<lb> -e WATCH_PATH=/sre-lab/version -e LAB_TOKEN=... loadtest/k6/canary-watch.js  # adds hostname

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { BASE_URL, ERROR_BUDGET, baseOptions, envFloat, envInt, envList, envStr } from './lib/config.js';
import { labHeaders, safeJson } from './lib/helpers.js';

const RATE = envInt('RATE', 10);
const DURATION = envStr('DURATION', '5m');
const WATCH_PATH = envStr('WATCH_PATH', '/ready');
const COLORS = ['blue', 'green', 'canary', 'stable', 'none']; // DEPLOY_COLOR values (CONVENTIONS §4)
const VERSIONS = envList('EXPECT_VERSIONS', []);
const CANARY_COLOR = envStr('CANARY_COLOR', '');
const CANARY_VERSION = envStr('CANARY_VERSION', '');
const EXPECT_PCT = envFloat('EXPECT_CANARY_PCT', -1);
const TOLERANCE_PCT = envFloat('TOLERANCE_PCT', 5);

const responses = new Counter('release_responses');
const latency = new Trend('release_latency', true);
const errors = new Rate('release_errors');
const canaryShare = new Rate('canary_share');

const thresholds = {
  // During a correct blue/green or canary shift, users see no errors at all.
  http_req_failed: [`rate<${envFloat('MAX_ERROR_RATE', ERROR_BUDGET)}`],
};
COLORS.forEach((c) => {
  thresholds[`release_responses{color:${c}}`] = ['count>=0'];
  thresholds[`release_latency{color:${c}}`] = ['max>=0'];
  thresholds[`release_errors{color:${c}}`] = ['rate>=0'];
});
VERSIONS.forEach((v) => {
  thresholds[`release_responses{version:${v}}`] = ['count>=0'];
  thresholds[`release_latency{version:${v}}`] = ['max>=0'];
  thresholds[`release_errors{version:${v}}`] = ['rate>=0'];
});
if (EXPECT_PCT >= 0 && (CANARY_COLOR || CANARY_VERSION)) {
  // Verifies the load balancer really applies the weight you configured.
  thresholds.canary_share = [
    `rate>=${Math.max(0, EXPECT_PCT - TOLERANCE_PCT) / 100}`,
    `rate<=${Math.min(100, EXPECT_PCT + TOLERANCE_PCT) / 100}`,
  ];
} else {
  thresholds.canary_share = ['rate>=0'];
}

export const options = baseOptions({
  noCookiesReset: false, // every iteration is a new client (see header)
  scenarios: {
    watch: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(5, RATE),
      maxVUs: Math.max(50, RATE * 5),
    },
  },
  thresholds,
});

export default function () {
  const res = http.get(`${BASE_URL}${WATCH_PATH}`, { headers: labHeaders(), tags: { name: 'canary-watch' } });
  const body = safeJson(res) || {};
  const tags = {
    version: typeof body.version === 'string' ? body.version : 'unknown',
    color: typeof body.color === 'string' ? body.color : 'unknown',
  };

  responses.add(1, tags);
  latency.add(res.timings.duration, tags);
  errors.add(res.status >= 500 || res.status === 0, tags);
  if (CANARY_COLOR || CANARY_VERSION) {
    const isCanary = (CANARY_COLOR && tags.color === CANARY_COLOR) || (CANARY_VERSION && tags.version === CANARY_VERSION);
    canaryShare.add(!!isCanary);
  }

  check(res, {
    'release answered 200': (r) => r.status === 200,
    'response says which release it is': () => tags.version !== 'unknown',
  });
}
