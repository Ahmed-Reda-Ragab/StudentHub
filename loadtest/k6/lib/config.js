// Env parsing + SLO thresholds shared by every k6 script.
//
// The env interface is the lab contract (docs/devops/CONVENTIONS.md §10) and the
// threshold numbers are the SLOs (§5): the same numbers live in the Prometheus
// recording/alerting rules and the CloudWatch alarms, so "k6 passed" and
// "the SLO dashboard is green" mean the same thing.

import './metrics.js'; // registers the custom metrics that the thresholds below reference

export function envStr(name, fallback) {
  const v = __ENV[name];
  return v === undefined || v === '' ? fallback : String(v);
}

export function envInt(name, fallback) {
  const v = __ENV[name];
  if (v === undefined || v === '') return fallback;
  const n = parseInt(v, 10);
  if (Number.isNaN(n)) throw new Error(`${name} must be an integer, got "${v}"`);
  return n;
}

export function envFloat(name, fallback) {
  const v = __ENV[name];
  if (v === undefined || v === '') return fallback;
  const n = parseFloat(v);
  if (Number.isNaN(n)) throw new Error(`${name} must be a number, got "${v}"`);
  return n;
}

export function envBool(name, fallback) {
  const v = __ENV[name];
  if (v === undefined || v === '') return fallback;
  return ['1', 'true', 'yes', 'on'].indexOf(String(v).toLowerCase()) !== -1;
}

export function envList(name, fallback) {
  const v = envStr(name, '');
  return v ? v.split(',').map((s) => s.trim()).filter(Boolean) : fallback;
}

// --- CONVENTIONS §10 -------------------------------------------------------
export const BASE_URL = envStr('BASE_URL', 'http://localhost:8080').replace(/\/+$/, '');
export const LAB_TOKEN = envStr('LAB_TOKEN', ''); // only needed when the app sets SRE_LAB_TOKEN
export const LOADTEST_USERS = Math.max(1, envInt('LOADTEST_USERS', 20)); // seeded by LoadTestSeeder
export const PASSWORD = envStr('PASSWORD', 'password');
export const P95_MS = envInt('P95_MS', 500); // CI default; the real SLO is 300ms (set P95_MS=300 on AWS)
export const P99_MS = envInt('P99_MS', 1000); // latency-tail SLO

// --- Lab extras (all optional) ---------------------------------------------
export const THINK_TIME = envFloat('THINK_TIME', 1); // seconds between page views (jittered ±50%)
export const WRITE_PCT = envFloat('WRITE_PCT', 5); // % of journey actions that create a student
export const LAB_ENDPOINTS = envBool('LAB_ENDPOINTS', true); // false = /sre-lab is disabled on the target
export const TEST_ID = envStr('TEST_ID', ''); // tag every sample (Grafana k6 dashboards filter on testid)

// --- SLOs (CONVENTIONS §5) -------------------------------------------------
export const SLO_AVAILABILITY = 0.995; // 99.5% of app requests are not 5xx over 30 days
export const ERROR_BUDGET = 0.005; // 1 - SLO, written out to avoid 0.0050000000000000044
export const SLO_LATENCY_MS = 300; // 95% of requests faster than 300ms (histogram bucket le="0.3")

// "45s", "5m", "1h30m", "500ms" or plain seconds → seconds.
export function parseDuration(value) {
  const s = String(value).trim();
  if (/^\d+(\.\d+)?$/.test(s)) return parseFloat(s);
  const re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  let total = 0;
  let matched = '';
  let m;
  while ((m = re.exec(s)) !== null) {
    const n = parseFloat(m[1]);
    total += m[2] === 'h' ? n * 3600 : m[2] === 'm' ? n * 60 : m[2] === 's' ? n : n / 1000;
    matched += m[0];
  }
  if (!matched || matched !== s) throw new Error(`Invalid duration "${value}" (use 45s, 5m, 1h30m...)`);
  return total;
}

export function seconds(n) {
  return `${Math.max(1, Math.round(n))}s`;
}

// Options every script shares. noCookiesReset keeps the Laravel session cookie for
// the whole life of a VU: each VU logs in ONCE (like a real user), instead of
// paying a bcrypt login on every iteration, which would turn a "browse" test into
// a "login" test.
export function baseOptions(extra) {
  const opts = {
    noCookiesReset: true,
    userAgent: 'student-app-k6/1.0 (+https://github.com/Ahmed-Reda-Ragab/StudentHub/tree/master/loadtest/k6)',
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
    insecureSkipTLSVerify: envBool('INSECURE_TLS', false),
    // Default system tags minus `url` (and subproto/service): every request has a
    // `name` tag already, and raw URLs (/students/123...) would explode label
    // cardinality once results are streamed to Prometheus. expected_response must stay.
    systemTags: ['proto', 'status', 'method', 'name', 'group', 'check', 'error', 'error_code', 'tls_version', 'scenario', 'expected_response'],
  };
  if (TEST_ID) opts.tags = { testid: TEST_ID };
  return Object.assign(opts, extra || {});
}

// Thresholds = SLOs. k6 exits with code 99 when any of them is crossed, which is
// what turns a load test into a CI gate.
//
// - http_req_failed counts 4xx/5xx/network errors (k6's default expected statuses
//   are 200-399, so a 419 CSRF failure is an error too — that is intentional).
// - Latency is measured on successful responses only ({expected_response:true}):
//   a fast 500 must never make p95 look better.
// - abortOnFail is for breakpoint tests: stop pushing once the SLO is clearly gone.
export function sloThresholds(o) {
  const opts = o || {};
  const p95 = opts.p95 === undefined ? P95_MS : opts.p95;
  const p99 = opts.p99 === undefined ? P99_MS : opts.p99; // null = no p99 gate
  const errorRate = opts.errorRate === undefined ? ERROR_BUDGET : opts.errorRate;
  const abort = !!opts.abortOnFail;
  const t = (expr) => (abort ? { threshold: expr, abortOnFail: true, delayAbortEval: opts.delayAbortEval || '1m' } : expr);

  const latency = [t(`p(95)<${p95}`)];
  if (p99 !== null) latency.push(t(`p(99)<${p99}`));

  const thresholds = {
    http_req_failed: [t(`rate<${errorRate}`)],
    'http_req_duration{expected_response:true}': latency,
    // Functional correctness: a page that returns 200 but is the login form is NOT a success.
    checks: [opts.checks || 'rate>0.99'],
    csrf_failures: ['count==0'],
    login_failures: ['count==0'],
  };
  // A session that silently expires mid-test points at a session-store problem
  // (DB/Redis sessions, APP_KEY mismatch between replicas). Soak tests allow it.
  if (!opts.allowRelogin) thresholds.session_relogins = ['count==0'];
  return thresholds;
}

// Shows per-page latency in the end-of-test summary without gating on it
// (k6 only prints sub-metrics that have a threshold; "max>=0" always passes).
export function showPerPage(names) {
  const out = {};
  names.forEach((n) => {
    out[`http_req_duration{name:${n}}`] = ['max>=0'];
  });
  return out;
}
