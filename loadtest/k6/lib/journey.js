// What a real back-office user does all day: mostly reading (list, search, open a
// student, dashboard, reports, notifications) and now and then adding a student.
//
// `name` tags use the Laravel route names, so a k6 result can be compared 1:1 with
// the app's own metric student_app_http_requests_total{route="students.index"}.
// (search/filter get their own k6 name because they cost more than the plain list.)

import http from 'k6/http';
import { check, group } from 'k6';
import exec from 'k6/execution';
import { BASE_URL, WRITE_PCT } from './config.js';
import {
  PAGE_HEADERS,
  extractCsrf,
  extractStudentIds,
  firstOfMonth,
  randomDigits,
  randomInt,
  randomItem,
  think,
  uuidv4,
  weightedPick,
  ymd,
} from './helpers.js';
import { currentSession, isAuthenticatedPage, landedOnLogin, sessionLost } from './auth.js';
import { csrfFailures, duplicateSubmissions, studentsCreated, validationFailures } from './metrics.js';

// app/Enums/Section.php — the store request validates against Rule::enum(Section::class).
export const SECTIONS = [
  'science', 'math', 'arts', 'azhar_science', 'azhar_arts',
  'track_medicine', 'track_engineering', 'track_humanities', 'track_business',
];
// app/Enums/SubscriptionStatus.php — the ?status= filter tabs.
const STATUSES = ['active', 'due_tomorrow', 'due_today', 'expired'];
// LoadTestSeeder codes are 500001.., phones 010/011/012/015.., names are Arabic (faker ar_EG).
const SEARCH_TERMS = ['5000', '50001', '50002', '010', '011', '012', 'محمد', 'أحمد', 'محمود', 'علي', 'سارة', 'مريم', 'k6-'];

// GET a page of the signed-in area. Returns the response, or null when the
// session is gone (we were bounced to /login) so the caller can stop the journey.
export function page(s, path, name) {
  const res = http.get(`${BASE_URL}${path}`, { headers: PAGE_HEADERS, tags: { name } });
  if (landedOnLogin(res)) {
    sessionLost();
    return null;
  }
  check(res, {
    [`${name}: status 200`]: (r) => r.status === 200,
    // A 200 that is not the signed-in layout (e.g. an error page from a proxy) is not a success.
    [`${name}: signed-in page`]: (r) => r.status !== 200 || isAuthenticatedPage(r),
  });
  const token = extractCsrf(res.body);
  if (token) s.csrf = token; // keep the freshest CSRF token for the next form
  return res;
}

export function studentsList(s) {
  const r = Math.random();
  let path = '/students';
  let name = 'students.index';
  if (r < 0.25) {
    path = `/students?status=${randomItem(STATUSES)}`;
    name = 'students.index?status';
  } else if (r < 0.35) {
    path = '/students?page=2';
  }
  const res = page(s, path, name);
  if (res && res.status === 200) {
    const ids = extractStudentIds(res.body);
    if (ids.length) s.studentIds = ids;
  }
  return res;
}

export function searchStudents(s) {
  return page(s, `/students?q=${encodeURIComponent(randomItem(SEARCH_TERMS))}`, 'students.index?q');
}

export function studentPage(s) {
  if (!s.studentIds || s.studentIds.length === 0) {
    const list = studentsList(s);
    if (!list || !s.studentIds || s.studentIds.length === 0) return list;
  }
  return page(s, `/students/${randomItem(s.studentIds)}`, 'students.show');
}

export function dashboard(s) {
  return page(s, '/dashboard', 'dashboard');
}

export function reports(s) {
  const today = ymd(0);
  const ranges = [
    '', // default: current month
    `?from=${firstOfMonth()}&to=${today}`,
    `?from=${ymd(30)}&to=${today}`,
    `?from=${today.slice(0, 4)}-01-01&to=${today}`,
  ];
  return page(s, `/reports${randomItem(ranges)}`, 'reports.index');
}

export function notifications(s) {
  return page(s, '/notifications', 'notifications.index');
}

// The write path: GET the form (fresh _token), POST it with a one-off
// _submission_token, land on /students/{id}. With replay=true the exact same
// request is sent again (double click / client retry): PreventDuplicateSubmissions
// must redirect to the SAME student instead of inserting a second one.
export function createStudent(s, opts) {
  const o = opts || {};
  const form = page(s, '/students/create', 'students.create');
  if (!form || form.status !== 200) return form;

  const payload = {
    _token: s.csrf,
    _submission_token: uuidv4(),
    name: `k6 Student ${randomDigits(5)}`,
    phone: `01${randomItem(['0', '1', '2', '5'])}${randomDigits(8)}`, // matches /^\+?[0-9\-()]{7,20}$/
    code: `k6-${exec.vu.idInTest}-${Date.now().toString(36)}-${randomDigits(4)}`, // unique per user, <= 50 chars
    section: randomItem(SECTIONS),
    subscribed_on: ymd(randomInt(0, 20)), // date_format:Y-m-d
    notes: 'created by k6 (loadtest/k6)',
    // price / commission omitted on purpose: the request merges the configured defaults.
  };
  const params = { headers: PAGE_HEADERS, tags: { name: 'students.store' } };

  const res = http.post(`${BASE_URL}/students`, payload, params);
  if (res.status === 419) csrfFailures.add(1);
  if (landedOnLogin(res)) {
    sessionLost();
    return null;
  }

  const created = res.status === 200 && /\/students\/\d+(\?|$)/.test(res.url || '');
  // Validation errors redirect back to the previous page (the form).
  if (res.status === 200 && /\/students\/create/.test(res.url || '')) validationFailures.add(1);

  check(res, {
    'students.store: no CSRF error (not 419)': (r) => r.status !== 419,
    'students.store: redirected to the new student': () => created,
  });

  const token = extractCsrf(res.body);
  if (token) s.csrf = token;

  if (created) {
    studentsCreated.add(1);
    s.studentIds = (s.studentIds || []).concat([res.url.match(/\/students\/(\d+)/)[1]]);

    if (o.replay) {
      const again = http.post(`${BASE_URL}/students`, payload, { headers: PAGE_HEADERS, tags: { name: 'students.store' } });
      const same = again.status === 200 && again.url === res.url;
      if (!same) duplicateSubmissions.add(1);
      check(again, { 'students.store replay: same student, no duplicate': () => same });
    }
  }
  return res;
}

// Read-heavy 95/5 mix (WRITE_PCT=5 by default). One call = one page view; the
// caller adds think time. Used by load/stress/spike/soak/breakpoint.
const ACTIONS = [
  { name: 'students.index', weight: 30, run: studentsList },
  { name: 'students.index?q', weight: 20, run: searchStudents },
  { name: 'students.show', weight: 20, run: studentPage },
  { name: 'dashboard', weight: 12, run: dashboard },
  { name: 'reports.index', weight: 8, run: reports },
  { name: 'notifications.index', weight: 5, run: notifications },
  { name: 'students.store', weight: WRITE_PCT, run: createStudent },
];

export function browse(s) {
  return weightedPick(ACTIONS).run(s);
}

// Page names used by the journey, for per-page latency in the summary.
export const PAGE_NAMES = [
  'login', 'students.index', 'students.index?q', 'students.index?status', 'students.show',
  'students.create', 'students.store', 'dashboard', 'reports.index', 'notifications.index',
];

// A scripted visit (user-journey.js): each step is a k6 group, so the summary and
// Grafana show group_duration per step — "how long does adding a student take?".
export const JOURNEY_STEPS = ['01-dashboard', '02-students-list', '03-search', '04-open-student', '05-add-student', '06-reports', '07-notifications'];

export function userJourney(s) {
  const steps = [
    ['01-dashboard', () => dashboard(s)],
    ['02-students-list', () => studentsList(s)],
    ['03-search', () => searchStudents(s)],
    ['04-open-student', () => studentPage(s)],
    ['05-add-student', () => (Math.random() * 100 < Math.min(100, WRITE_PCT * 4) ? createStudent(s, { replay: true }) : null)],
    ['06-reports', () => reports(s)],
    ['07-notifications', () => notifications(s)],
  ];
  for (let i = 0; i < steps.length; i++) {
    if (currentSession() !== s) return; // session lost: next iteration logs in again
    group(steps[i][0], steps[i][1]);
    think();
  }
}
