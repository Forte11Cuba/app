#!/usr/bin/env node
// Headless-Chrome smoke test for the release web bundle (issue #154).
//
// The static guards around this bundle — the "Verify bundle" step in
// web-build.yml and test/web/pages_bundle_test.dart — only grep files. Every
// blank-page cause documented in CLAUDE.md under "Web (wasm) — non-obvious
// constraints" greps perfectly clean and fails at runtime, so this test loads
// the real artifact in a real browser and asserts it is alive:
//
//   1. the page is cross-origin isolated  (no SharedArrayBuffer → no wasm threads)
//   2. the Flutter engine mounted         (the view element exists)
//   3. a Rust bridge call returned        (the FRB worker pool survived)
//   4. nothing errored along the way      (console + uncaught page errors)
//   5. every asset the page asked for was served (catches --base-href breakage)
//
// (3) is what separates this from a "did the HTML load" test: a DataCloneError
// kills the worker pool while the DOM still looks perfectly healthy.
//
// The bundle is served with COOP/COEP set directly rather than through
// web/coi-serviceworker.min.js. The shim only registers when the headers are
// absent and takes effect one load late, which would make a first-load
// assertion flaky; serving the headers reaches the same isolated state
// deterministically. That is also why the shim is inert here — it is covered
// statically by pages_bundle_test.dart instead.
//
// Usage:
//   BUNDLE_DIR=../../../build/web BASE_PATH=/app/ node smoke.mjs

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));

/** The bundle under test. Must be the release build that actually ships. */
const BUNDLE_DIR = resolve(process.env.BUNDLE_DIR || join(here, '../../../build/web'));

/**
 * Sub-path the bundle is served from, matching production (`/app/`). Serving
 * from the root instead would let a broken `--base-href` pass here and fail
 * only once deployed to Pages.
 */
const BASE_PATH = process.env.BASE_PATH || '/app/';

/** Generous: a cold CI runner instantiates the wasm core before anything runs. */
const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS || 120_000);

const MIME = {
  '.bin': 'application/octet-stream',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.otf': 'font/otf',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.symbols': 'text/plain; charset=utf-8',
  '.ttf': 'font/ttf',
  '.wasm': 'application/wasm',
  '.woff2': 'font/woff2',
};

/**
 * Console/page errors that say nothing about the bundle.
 *
 * The app dials real Nostr relays on startup; one being unreachable from a CI
 * runner is a fact about the internet, not about this build. Keep this list
 * narrow — anything broader hides the failures this test exists to catch.
 * Ignored entries are still printed.
 */
const IGNORABLE = [/WebSocket connection to 'wss:\/\//i, /favicon\.ico/i];

const isIgnorable = (text) => IGNORABLE.some((re) => re.test(text));

/**
 * Serves BUNDLE_DIR under BASE_PATH, cross-origin isolated.
 *
 * Every request it cannot satisfy is pushed to [misses]: a page whose
 * `--base-href` was not rewritten asks for `/main.dart.js` instead of
 * `/app/main.dart.js`, and that miss is the earliest unambiguous signal of it.
 */
function serveBundle(misses) {
  const server = createServer(async (req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);

    const send = (status, body, type) => {
      res.writeHead(status, {
        'Content-Type': type || 'text/plain; charset=utf-8',
        // The whole point: SharedArrayBuffer, and therefore wasm threads.
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
        'Cross-Origin-Resource-Policy': 'same-origin',
        'Cache-Control': 'no-store',
      });
      res.end(body);
    };

    if (!pathname.startsWith(BASE_PATH)) {
      misses.push(pathname);
      return send(404, `outside ${BASE_PATH}`);
    }

    let rel = pathname.slice(BASE_PATH.length);
    if (rel === '' || rel.endsWith('/')) rel += 'index.html';

    // Containment check: normalize collapses any ../ before we touch the disk.
    const file = normalize(join(BUNDLE_DIR, rel));
    if (!file.startsWith(BUNDLE_DIR)) {
      misses.push(pathname);
      return send(403, 'forbidden');
    }

    try {
      const body = await readFile(file);
      send(200, body, MIME[extname(file).toLowerCase()]);
    } catch {
      misses.push(pathname);
      send(404, 'not found');
    }
  });

  return new Promise((ok, fail) => {
    server.on('error', fail);
    server.listen(0, '127.0.0.1', () => ok(server));
  });
}

async function main() {
  // Fail with a useful message rather than 404-ing every asset.
  await readFile(join(BUNDLE_DIR, 'index.html')).catch(() => {
    throw new Error(
      `No bundle at ${BUNDLE_DIR}. Build it first:\n` +
        '  ./scripts/build-web.sh --release && flutter build web --release ' +
        `--base-href "${BASE_PATH}" --pwa-strategy=none`,
    );
  });

  const misses = [];
  const errors = [];
  const ignored = [];

  const server = await serveBundle(misses);
  const { port } = server.address();
  const url = `http://127.0.0.1:${port}${BASE_PATH}`;
  console.log(`serving ${BUNDLE_DIR} at ${url}`);

  const browser = await chromium.launch();
  const page = await browser.newPage();

  const record = (origin, text) => {
    (isIgnorable(text) ? ignored : errors).push(`[${origin}] ${text}`);
  };
  page.on('console', (msg) => {
    if (msg.type() === 'error') record('console', msg.text());
  });
  page.on('pageerror', (err) => record('pageerror', err.message));

  const fail = async (message) => {
    await page.screenshot({ path: 'smoke-failure.png' }).catch(() => {});
    throw new Error(message);
  };

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: TIMEOUT_MS });

    // 1. Isolation. Cheap, unambiguous, and everything after it depends on it.
    const isolated = await page.evaluate(() => globalThis.crossOriginIsolated);
    if (isolated !== true) {
      await fail('page is not cross-origin isolated — SharedArrayBuffer is unavailable');
    }
    console.log('✓ cross-origin isolated');

    // 2. The engine mounted. Flutter paints to canvas, so there is no text to
    //    assert on — the view element is the observable signal.
    await page
      .waitForSelector('flutter-view, flt-glass-pane', { timeout: TIMEOUT_MS })
      .catch(() => fail('the Flutter view never mounted'));
    console.log('✓ Flutter view mounted');

    // 3. The Rust bridge answered. Poll for either outcome so a broken bridge
    //    fails immediately with its reason instead of timing out silently.
    await page
      .waitForFunction(
        () =>
          globalThis.mostroBridgeReady === true ||
          typeof globalThis.mostroBridgeError === 'string',
        undefined,
        { timeout: TIMEOUT_MS },
      )
      .catch(() =>
        fail(
          'no Rust bridge call completed — the FRB worker pool is probably dead ' +
            '(DataCloneError); check that web/pkg was built by scripts/build-web.sh',
        ),
      );
    const bridgeError = await page.evaluate(() => globalThis.mostroBridgeError);
    if (bridgeError) await fail(`Rust bridge call failed: ${bridgeError}`);
    console.log('✓ Rust bridge call returned');

    // 4/5. Anything the page complained about, and anything it asked for that
    //      this server could not serve.
    if (ignored.length) {
      console.log("\nignored (outside this bundle's control):");
      for (const e of ignored) console.log(`  ${e}`);
    }
    if (misses.length) {
      await fail(`unserved requests (check --base-href):\n  ${misses.join('\n  ')}`);
    }
    if (errors.length) {
      await fail(`page reported errors:\n  ${errors.join('\n  ')}`);
    }
    console.log('✓ no console or page errors\n\nweb bundle smoke test passed.');
  } finally {
    await browser.close().catch(() => {});
    server.close();
  }
}

main().catch((err) => {
  console.error(`\n✗ web bundle smoke test failed: ${err.message}`);
  process.exitCode = 1;
});
