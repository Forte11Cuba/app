#!/usr/bin/env node
// Behavioural test for smoke.mjs itself.
//
// smoke.mjs is a gate, and a gate nobody tests is a gate that quietly stops
// gating. Grepping its source cannot prove it fails when it should: mutate
// `if (errors.length)` to `if (false)` and every source assertion still
// passes, while a healthy release bundle produces a green run either way — so
// issue #154's "fail on any console error" requirement would be gone with
// nothing to show for it.
//
// So run the real script, unmodified, against fixtures that differ by exactly
// one thing, and assert the exit code. The healthy fixture is the control: it
// is what makes a failure in the other two mean "the error was detected"
// rather than "the fixture never loaded".
//
// Cheap — three static pages, no build required. Runs in CI before the real
// bundle smoke test, so a broken harness is reported as a broken harness
// rather than as a broken bundle.
//
// Usage:  node selftest.mjs

import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

const CASES = [
  {
    fixture: 'healthy',
    expected: 0,
    what: 'a page with a mounted view and a live bridge passes',
  },
  {
    fixture: 'console-error',
    expected: 1,
    what: 'one console.error fails the run',
  },
  {
    fixture: 'page-error',
    expected: 1,
    what: 'one uncaught page error fails the run',
  },
];

let failures = 0;

for (const { fixture, expected, what } of CASES) {
  const result = spawnSync(process.execPath, [join(here, 'smoke.mjs')], {
    cwd: here,
    encoding: 'utf8',
    env: {
      ...process.env,
      BUNDLE_DIR: join(here, 'fixtures', fixture),
      BASE_PATH: '/app/',
      // Static fixtures load instantly; no reason to wait out the bundle's
      // budget when something is wrong.
      SMOKE_TIMEOUT_MS: '30000',
    },
  });

  const actual = result.status;
  const ok = actual === expected;
  console.log(`${ok ? '✓' : '✗'} ${what} — exit ${actual}, expected ${expected}`);

  if (!ok) {
    failures += 1;
    // Only on failure: the passing cases' output is noise, and smoke.mjs is
    // deliberately chatty when it fails.
    if (result.stdout) console.log(result.stdout.trimEnd());
    if (result.stderr) console.error(result.stderr.trimEnd());
    if (result.error) console.error(result.error);
  }
}

if (failures) {
  console.error(`\n✗ smoke.mjs self-test: ${failures} of ${CASES.length} cases failed.`);
  process.exitCode = 1;
} else {
  console.log(`\n✓ smoke.mjs self-test: all ${CASES.length} cases behaved as expected.`);
}
