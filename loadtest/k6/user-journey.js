// User-journey test — "how long does a real task take end to end, step by step?"
//
// Each VU logs in once, then repeats a scripted visit: dashboard → students list
// → search → open a student → (sometimes) add a student and double-submit it →
// reports → notifications. Every step is a k6 group, so the summary shows
// group_duration per step (what a user feels), not just per request.
//
// It also proves two correctness properties under concurrency:
//   - CSRF + session survive the whole journey (csrf_failures == 0)
//   - a replayed _submission_token never creates a duplicate student (duplicate_submissions == 0)
//
//   k6 run -e BASE_URL=... -e VUS=5 -e DURATION=5m loadtest/k6/user-journey.js

import { baseOptions, envInt, envStr, showPerPage, sloThresholds } from './lib/config.js';
import { ensureSession } from './lib/auth.js';
import { JOURNEY_STEPS, PAGE_NAMES, userJourney } from './lib/journey.js';

const groupThresholds = {};
JOURNEY_STEPS.forEach((g) => {
  groupThresholds[`group_duration{group:::${g}}`] = ['max>=0']; // display only
});

export const options = baseOptions({
  scenarios: {
    journey: {
      executor: 'constant-vus',
      vus: envInt('VUS', 5),
      duration: envStr('DURATION', '5m'),
      gracefulStop: '30s',
    },
  },
  thresholds: Object.assign(
    sloThresholds(),
    {
      duplicate_submissions: ['count==0'],
      validation_failures: ['count==0'],
    },
    showPerPage(PAGE_NAMES),
    groupThresholds,
  ),
});

export default function () {
  const s = ensureSession();
  if (!s) return;
  userJourney(s);
}
