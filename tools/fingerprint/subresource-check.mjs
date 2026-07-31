// Reports which subresource types actually reach the server, and with which
// headers.
//
//   node tools/fingerprint/subresource-check.mjs [-- <extra lightpanda flags>]
//   node tools/fingerprint/subresource-check.mjs -- --enable-external-stylesheets
//
// A client that never fetches CSS, images or the favicon is trivially
// separable server-side regardless of how correct its document headers are, so
// this asks the narrow question the header snapshots can't: did the request
// happen at all? Prints one row per fetch destination and exits non-zero if any
// expected destination was missing, which makes it usable as a check.
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, sleep } from './cdp.mjs';
import { startEchoServer } from './header-echo.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const PORT = 9227;

// Paths the index page references, by the fetch destination each stands for.
const EXPECTED = [
    ['document', '/'],
    ['script', '/asset.js'],
    ['iframe', '/frame.html'],
    ['fetch', '/api/fetch'],
    ['xhr', '/api/xhr'],
    ['stylesheet', '/asset.css'],
    ['image', '/asset.png'],
    ['favicon', '/favicon.ico'],
];

const sep = process.argv.indexOf('--');
const extraFlags = sep === -1 ? [] : process.argv.slice(sep + 1);

const bin = path.join(repo, 'zig-out/bin/lightpanda');
const serverLog = [];
const proc = spawn(
    bin,
    ['serve', '--host', '127.0.0.1', '--port', String(PORT), ...extraFlags],
    { stdio: ['ignore', 'pipe', 'pipe'] },
);
proc.stdout.on('data', (d) => serverLog.push(String(d)));
proc.stderr.on('data', (d) => serverLog.push(String(d)));

let missing = [];
try {
    let up = false;
    for (let i = 0; i < 50; i++) {
        try {
            await fetch(`http://127.0.0.1:${PORT}/json/version`);
            up = true;
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!up) throw new Error(`lightpanda CDP never came up\n${serverLog.join('')}`);

    const echo = await startEchoServer(0);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await goto(cdp, sessionId, `http://127.0.0.1:${echo.port}/`, { settleMs: 3000 });

    const flagNote = extraFlags.length ? ` (flags: ${extraFlags.join(' ')})` : '';
    console.log(`subresource requests reaching the server${flagNote}:\n`);
    for (const [dest, p] of EXPECTED) {
        const hit = echo.records.find((r) => r.path === p);
        if (!hit) {
            missing.push(dest);
            console.log(`  MISS  ${dest.padEnd(11)} ${p}`);
            continue;
        }
        const pick = (n) => (hit.headers.find(([k]) => k.toLowerCase() === n) || [, '—'])[1];
        console.log(`  HIT   ${dest.padEnd(11)} ${p}`);
        console.log(`          accept:          ${pick('accept')}`);
        console.log(`          sec-fetch-dest:  ${pick('sec-fetch-dest')}`);
        console.log(`          sec-fetch-mode:  ${pick('sec-fetch-mode')}`);
        console.log(`          sec-fetch-site:  ${pick('sec-fetch-site')}`);
    }
    console.log(`\n${EXPECTED.length - missing.length}/${EXPECTED.length} destinations requested.`);
    if (missing.length) console.log(`missing: ${missing.join(', ')}`);

    await echo.close();
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    process.exit(missing.length ? 1 : 0);
}
