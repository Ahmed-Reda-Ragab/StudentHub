// Autoscaling drill — "does CPU-based scaling (ASG target tracking, ECS Service
// Auto Scaling, Kubernetes HPA) add capacity in time, and remove it afterwards?"
//
// constant-arrival-rate sends RATE req/s to /sre-lab/cpu?ms=CPU_MS for DURATION.
// Every request burns CPU_MS of pure PHP CPU, so the demand is predictable:
//
//   CPU demand (vCPU) = RATE × CPU_MS / 1000
//   e.g. RATE=10, CPU_MS=200  →  10 × 0.2 = 2 vCPU busy all the time
//
//   capacity needed = demand / (vCPU per unit × target utilisation)
//     ASG  t3.small (2 vCPU), target 50%  → 2 / (2 × 0.5)   = 2 instances
//     ECS  task 0.5 vCPU,     target 50%  → 2 / (0.5 × 0.5) = 8 tasks  (> stack 50 max 6: you SEE the ceiling — lower RATE to 6 to stay inside it)
//     HPA  requests.cpu=100m, target 70%  → 2 / (0.1 × 0.7) ≈ 29 pods (chart maxReplicas 6: pinned at the ceiling — use RATE=2 CPU_MS=100 to watch it scale 2→N)
//
// Start with min capacity below that number and watch the scaling activity,
// CPUUtilization and p95 recover. After the test, scale-in takes longer than
// scale-out on purpose (cooldowns / stabilisation windows) — keep watching ~15 min.
//
// A second, tiny scenario asks /sre-lab/version once per second and logs every
// NEW hostname that answers: that is the moment new capacity starts taking traffic.
//
//   k6 run -e BASE_URL=http://<alb-dns> -e LAB_TOKEN=... -e RATE=10 -e CPU_MS=200 -e DURATION=15m loadtest/k6/autoscale-cpu.js
//
// The cap SRE_LAB_MAX_CPU_MS (5000) applies; PHP-FPM pm.max_children also limits
// how many requests one instance burns in parallel (extra ones queue → latency).

import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE_URL, baseOptions, envInt, envStr } from './lib/config.js';
import { labParams, safeJson } from './lib/helpers.js';

const RATE = envInt('RATE', 10);
const CPU_MS = envInt('CPU_MS', 200);
const DURATION = envStr('DURATION', '10m');

const servedBy = new Counter('served_by'); // tagged with hostname → per-instance split in Prometheus/Grafana
const seenHosts = {}; // per VU

export const options = baseOptions({
  scenarios: {
    cpu: {
      executor: 'constant-arrival-rate',
      exec: 'burn',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      // Little's law: concurrent requests = rate × response time. Room for 3× slowdown at start…
      preAllocatedVUs: Math.ceil(RATE * (CPU_MS / 1000) * 3) + 5,
      // …and up to MAX_VUS while the system is saturated, before k6 starts dropping iterations.
      maxVUs: envInt('MAX_VUS', Math.max(50, RATE * 10)),
    },
    whoami: {
      executor: 'constant-arrival-rate',
      exec: 'whoami',
      rate: 1,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 2,
      maxVUs: 10,
    },
  },
  thresholds: {
    // Not the SLO: the drill is about capacity. More than 5% errors means scaling did
    // not keep up (or the instance cap / PHP-FPM workers were hit first).
    'http_req_failed{scenario:cpu}': ['rate<0.05'],
    'http_req_duration{name:sre-lab.cpu}': ['max>=0'], // display p95/p99 in the summary
    dropped_iterations: ['count>=0'],
  },
});

export function burn() {
  const res = http.get(`${BASE_URL}/sre-lab/cpu?ms=${CPU_MS}`, labParams('sre-lab.cpu', { timeout: '30s' }));
  check(res, { 'sre-lab cpu: 200': (r) => r.status === 200 });
}

export function whoami() {
  const res = http.get(`${BASE_URL}/sre-lab/version`, labParams('sre-lab.version'));
  const body = safeJson(res);
  if (!body || !body.hostname) return;
  servedBy.add(1, { hostname: String(body.hostname), version: String(body.version), color: String(body.color) });
  if (!seenHosts[body.hostname]) {
    seenHosts[body.hostname] = true;
    console.log(`instance serving traffic: ${body.hostname} (version=${body.version}, color=${body.color})`);
  }
}
