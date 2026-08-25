#!/usr/bin/env node
// The other half of prop-reads.mjs: which members a page asked us for that we
// do not have.
//
// `prop-reads.mjs` lists what the engine answered; this lists what it could not
// answer at all. Both come from the same Debug-only bookkeeping on the Context
// (js/Context.zig `unknown_properties`), dumped when the context is torn down,
// and both need the same two things from a driver: the target has to be *closed*
// (SIGKILL prints nothing) and `Runtime.enable` has to stay off until the
// settle is over, because the guard changes its mind when it is watched.
//
// Most of what comes back is a bot-detection sentinel that no browser has --
// `_phantom`, `cdc_adoQpoasnfa76pfcZLmcfl_Array`, `domAutomationController`,
// `callSelenium` -- and being absent is the right answer there. What matters is
// the handful Chrome *does* have: on the macys interstitial that was
// `FontFaceSet[Symbol.iterator]`, `WorkerNavigator.connection` and
// `RestrictionTarget`, and the first two were real gaps.
//
// usage:
//   unknown-props.mjs <url> [--out results/x.json] [--settle 25000]
//                          [--proxy socks5h://host:port] [--port 9700]

import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

const url = process.argv[2];
if (!url || url.startsWith('--')) {
    console.error('usage: prop-reads.mjs <url> [--out results/x.json] [--settle ms] [--proxy p] [--port n]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const outPath = path.resolve(repo, arg('--out', 'tools/fingerprint/results/prop-reads.json'));
const settleMs = Number(arg('--settle', '25000'));
const proxy = arg('--proxy', null);
const PORT = Number(arg('--port', '9700'));

let out = '';
const proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
    'serve', '--host', '127.0.0.1', '--port', String(PORT),
    // logfmt rather than the debug default: one line per member, parseable.
    '--log-level', 'debug', '--log-format', 'logfmt',
    '--log-filter-scopes', '-all', '--log-filter-scopes', '+unknown_prop',
    ...(proxy ? ['--http-proxy', proxy] : []),
], { stdio: ['ignore', 'pipe', 'pipe'] });
const keep = (b) => { out += b.toString(); };
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);

const row = { url, settleMs, when: new Date().toISOString() };
// A fixed sleep before connecting is a race the engine loses often enough to
// look like a station failure: what comes back is a websocket error with the
// engine's own startup output nowhere in sight.
const cdp = new Cdp(`ws://127.0.0.1:${PORT}`);
let opened = false;
for (let i = 0; i < 25 && !opened; i++) {
    await sleep(400);
    try {
        await cdp.open();
        opened = true;
    } catch { /* not listening yet */ }
}
if (!opened) {
    proc.kill('SIGKILL');
    console.error(`engine never accepted a connection on ${PORT}\n${out.slice(-2000)}`);
    process.exit(1);
}
try {
    const { sessionId, targetId } = await newPage(cdp);
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Network.enable', {}, sessionId);
    await cdp.send('Page.navigate', { url }, sessionId);
    await sleep(settleMs);

    // Only now, with the guard's verdict already decided, is it safe to look.
    await cdp.send('Runtime.enable', {}, sessionId);
    row.reading = await evaluate(cdp, sessionId,
        '({href: location.href, title: document.title, nodes: document.getElementsByTagName("*").length})');
    await cdp.send('Runtime.disable', {}, sessionId);

    // The line that makes the engine talk. Without it the context is still
    // alive when we kill the process and the whole log is lost.
    await cdp.send('Target.closeTarget', { targetId });
    await sleep(1500);
} catch (e) {
    row.error = String((e && e.message) || e).slice(0, 300);
}
cdp.close();
proc.kill('SIGKILL');
await sleep(300);

// property=Navigator.userAgent occurrences=2 seq=7
//
// The quoted form has to tolerate escapes: an interface with no Meta.name
// falls back to its Zig type name, and a generic one of those carries commas
// and quotes of its own (`Entry(...DOMStringList.Iterator,\"...`).
const reads = [];
for (const line of out.split('\n')) {
    if (!line.includes('unknown_prop')) continue;
    const property = /property=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1];
    if (!property) continue;
    let name = property;
    if (name.startsWith('"')) {
        try { name = JSON.parse(name); } catch { name = name.slice(1, -1); }
    }
    // `scope=` is the log's own field (it says prop_read); the realm's url is
    // ours.
    const realm = /realm=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1] ?? '';
    reads.push({
        context: Number(/context=(\d+)/.exec(line)?.[1] ?? -1),
        realm: realm.startsWith('"') ? realm.slice(1, -1) : realm,
        seq: Number(/seq=(\d+)/.exec(line)?.[1] ?? -1),
        property: name,
        occurrences: Number(/occurrences=(\d+)/.exec(line)?.[1] ?? 0),
    });
}
// Grouped by context, then by the order within it. Every context counts from
// zero, so a flat sort on `seq` would braid the page's walk together with its
// iframes' into a sequence nothing performed.
reads.sort((a, b) => (a.context - b.context) || (a.seq - b.seq));
row.reads = reads;
row.contexts = [...new Set(reads.map((r) => r.context))]
    .map((id) => ({
        context: id,
        realm: reads.find((r) => r.context === id)?.realm,
        members: reads.filter((r) => r.context === id).length,
    }));
row.interfaces = [...new Set(reads.map((r) => r.property.split('.')[0]))].sort();

await fs.mkdir(path.dirname(outPath), { recursive: true });
await fs.writeFile(outPath, JSON.stringify(row, null, 2));
console.log(`${reads.length} members read across ${row.interfaces.length} interfaces in ${row.contexts.length} contexts -> ${path.relative(repo, outPath)}`);
if (row.reading) console.log(`  ${row.reading.nodes} nodes  ${row.reading.href}`);
if (row.error) console.log(`  error: ${row.error}`);
