// Real Laravel login: GET /login → parse _token → POST the form → follow the
// redirect to /students. One login per VU; the session cookie lives in the VU's
// cookie jar (scripts set noCookiesReset: true, see config.baseOptions).
//
// Failure modes we detect explicitly (they all look like "200 OK" otherwise):
//   419           → CSRF token mismatch (stale/missing _token, cookie not kept)
//   back on /login → wrong password, throttled (5 failures/min per email+IP), or session lost

import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { BASE_URL, LOADTEST_USERS, PASSWORD } from './config.js';
import { PAGE_HEADERS, extractCsrf, extractStudentIds, uuidv4 } from './helpers.js';
import { csrfFailures, loginDuration, loginFailures, sessionRelogins } from './metrics.js';

// Module scope = per VU: every VU runs its own copy of this module.
let current = null;

// VU 1 → loadtest1@example.com ... wraps around when VUs > LOADTEST_USERS
// (several VUs then share one account, like a user with two tabs open).
export function vuEmail() {
  const n = ((exec.vu.idInTest - 1) % LOADTEST_USERS) + 1;
  return `loadtest${n}@example.com`;
}

export function isAuthenticatedPage(res) {
  // Every page of the signed-in layout has the logout form; the guest layout does not.
  return typeof res.body === 'string' && res.body.indexOf('/logout') !== -1;
}

export function landedOnLogin(res) {
  return res.status === 200 && /\/login(\?|$)/.test(res.url || '');
}

// Returns a session object { email, csrf, studentIds } or null.
export function login(email, password) {
  const started = Date.now();

  const form = http.get(`${BASE_URL}/login`, { headers: PAGE_HEADERS, tags: { name: 'login' } });

  // Guest middleware sends an already signed-in user to /students: reuse that session.
  if (form.status === 200 && isAuthenticatedPage(form)) {
    return newSession(email, form);
  }

  const token = extractCsrf(form.body);
  const formOk = check(form, {
    'login form: 200 with a _token': (r) => r.status === 200 && !!token,
  });
  if (!formOk) {
    loginFailures.add(1);
    return null;
  }

  // Same fields as the real form (x-form adds _submission_token to every POST form;
  // the idempotency middleware ignores it for guests, but we send what a browser sends).
  const res = http.post(
    `${BASE_URL}/login`,
    { _token: token, _submission_token: uuidv4(), email, password: password || PASSWORD },
    { headers: PAGE_HEADERS, tags: { name: 'login' } },
  );

  if (res.status === 419) csrfFailures.add(1);

  const ok = check(res, {
    'login: no CSRF error (not 419)': (r) => r.status !== 419,
    'login: redirected to /students and signed in': (r) =>
      r.status === 200 && /\/students(\?|$)/.test(r.url || '') && isAuthenticatedPage(r),
  });
  loginDuration.add(Date.now() - started);

  if (!ok) {
    loginFailures.add(1);
    return null;
  }
  return newSession(email, res);
}

function newSession(email, res) {
  return {
    email,
    // session()->regenerate() on login also rotates the CSRF token, so the token
    // from the login form is dead now: take the fresh one from the landing page.
    csrf: extractCsrf(res.body),
    studentIds: extractStudentIds(res.body),
    since: Date.now(),
  };
}

// Lazy, once per VU. Returns null (after a back-off) when login is impossible, so the
// caller just skips the iteration instead of hammering /login (and the throttle).
export function ensureSession() {
  if (current) return current;
  current = login(vuEmail(), PASSWORD);
  if (!current) sleep(5);
  return current;
}

// Called when a page bounced us to /login (expired/invalidated session).
export function sessionLost() {
  sessionRelogins.add(1);
  current = null;
}

export function currentSession() {
  return current;
}
