// Small, dependency-free helpers (no remote jslib imports: the scripts must run
// offline, on a locked-down runner, and inside the grafana/k6 image as-is).

import { sleep } from 'k6';
import { LAB_TOKEN, THINK_TIME } from './config.js';

// Headers a browser sends for a normal page view. We deliberately do NOT send
// Sec-Fetch-Site: Laravel 13's PreventRequestForgery accepts "same-origin" requests
// without a token, and the point of this lab is to exercise the real _token path.
export const PAGE_HEADERS = {
  Accept: 'text/html,application/xhtml+xml',
  'Accept-Language': 'ar,en;q=0.8',
};

// RFC 4122 version-4 UUID, what PreventDuplicateSubmissions expects in _submission_token
// (it only checks Str::isUuid). Uses Web Crypto when the k6 build exposes it.
export function uuidv4() {
  const b = new Uint8Array(16);
  if (typeof crypto !== 'undefined' && crypto && typeof crypto.getRandomValues === 'function') {
    crypto.getRandomValues(b);
  } else {
    for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  }
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  const h = [];
  for (let i = 0; i < 16; i++) h.push((b[i] + 0x100).toString(16).slice(1));
  return `${h.slice(0, 4).join('')}-${h.slice(4, 6).join('')}-${h.slice(6, 8).join('')}-${h.slice(8, 10).join('')}-${h.slice(10).join('')}`;
}

export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function randomItem(list) {
  return list[Math.floor(Math.random() * list.length)];
}

export function randomDigits(n) {
  let s = '';
  for (let i = 0; i < n; i++) s += String(Math.floor(Math.random() * 10));
  return s;
}

// entries: [{ weight, ... }] → one entry, chosen proportionally to weight.
export function weightedPick(entries) {
  const total = entries.reduce((sum, e) => sum + Math.max(0, e.weight), 0);
  let r = Math.random() * total;
  for (let i = 0; i < entries.length; i++) {
    r -= Math.max(0, entries[i].weight);
    if (r < 0) return entries[i];
  }
  return entries[entries.length - 1];
}

// Think time with ±50% jitter so VUs never march in lockstep (lockstep traffic
// produces artificial latency waves that real users never create).
export function think(base) {
  const b = base === undefined ? THINK_TIME : base;
  if (b > 0) sleep(b * (0.5 + Math.random()));
}

// X-Lab-Token is only required when the app runs with SRE_LAB_TOKEN set (EnsureSreLabEnabled).
export function labHeaders(extra) {
  const h = Object.assign({ Accept: 'application/json' }, extra || {});
  if (LAB_TOKEN) h['X-Lab-Token'] = LAB_TOKEN;
  return h;
}

export function labParams(name, extra) {
  return Object.assign({ headers: labHeaders(), tags: { name } }, extra || {});
}

// Y-m-d (UTC) n days ago — the format the store/report validators require.
export function ymd(daysAgo) {
  return new Date(Date.now() - (daysAgo || 0) * 86400000).toISOString().slice(0, 10);
}

export function firstOfMonth() {
  return `${ymd(0).slice(0, 7)}-01`;
}

// @csrf renders <input type="hidden" name="_token" value="..." autocomplete="off">,
// the app layout also has <meta name="csrf-token" content="...">.
export function extractCsrf(body) {
  if (typeof body !== 'string') return null;
  const m = body.match(/name="_token"\s+value="([^"]+)"/) || body.match(/<meta name="csrf-token" content="([^"]+)"/);
  return m ? m[1] : null;
}

// Student ids from links like href="http://host/students/123" (only the signed-in
// user's students are listed: the tenant scope 404s everyone else's).
export function extractStudentIds(body) {
  if (typeof body !== 'string') return [];
  const ids = {};
  const re = /\/students\/(\d+)(?=["'\/?#])/g;
  let m;
  while ((m = re.exec(body)) !== null) ids[m[1]] = true;
  return Object.keys(ids);
}

export function safeJson(res) {
  try {
    return res.json();
  } catch (e) {
    return null;
  }
}
