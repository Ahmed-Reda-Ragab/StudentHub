// Custom metrics, defined once (k6 requires metrics to exist in the init context
// before a threshold can reference them).

import { Counter, Trend } from 'k6/metrics';

// Laravel answers 419 "Page Expired" when _token does not match the session.
export const csrfFailures = new Counter('csrf_failures');
// Login form unreachable, wrong credentials, throttled, or did not land on /students.
export const loginFailures = new Counter('login_failures');
// Session lost mid-test (redirected back to /login) → we log in again.
export const sessionRelogins = new Counter('session_relogins');
// Store request redirected back to the form (validation error) instead of the new student.
export const validationFailures = new Counter('validation_failures');
export const studentsCreated = new Counter('students_created');
// A replayed _submission_token must land on the SAME student (idempotency), not create a twin.
export const duplicateSubmissions = new Counter('duplicate_submissions');
// Full login flow: GET /login + POST /login + redirect to /students.
export const loginDuration = new Trend('login_duration', true);
