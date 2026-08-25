#!/usr/bin/env node
// What of our surface a page actually reached, in the order it reached it.
//
// The sweep says whether a station passed. `unknown_prop` says which members
// the page asked for and we don't have. Neither says anything about the third
// case, which is the one left on x-hyatt: a member we do have, answered
// differently from Chrome, read once and never mentioned again. The engine
// records those now (js/bridge.zig logReads); this drives a run that makes it
// speak and turns the log back into a list.
//
// Two things the engine needs from the driver, both easy to get wrong:
//
//   * The dump happens when the context is torn down, so the target has to be
//     closed. SIGKILL -- which is how the sweep ends a station -- produces an
//     empty log every time.
//   * Runtime.enable is detectable (see antibot-sweep.mjs), so it stays off
//     until the settle is over. The reads we want are the ones the guard made
//     while it still believed nobody was watching.
//
// `--args` adds the second half of the same question. Without it an operation
// is logged by name, so a guard that called matchMedia 431 times reads as one
// line saying 431 -- the members it asked about are the whole point and none of
// them are in there. With it the key carries the call's first argument, which
// for matchMedia / getParameter / canPlayType / isTypeSupported is the entire
// question. Off by default: the key set stops being bounded by our surface and
// starts being bounded by whatever the page passes.
//
// usage:
//   prop-reads.mjs <url> [--out results/x.json] [--settle 25000]
//                        [--proxy socks5h://host:port] [--port 9700] [--args]
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
const withArgs = process.argv.includes('--args');

let out = '';
const proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
    'serve', '--host', '127.0.0.1', '--port', String(PORT),
    // logfmt rather than the debug default: one line per member, parseable.
    '--log-level', 'debug', '--log-format', 'logfmt',
    '--log-filter-scopes', '-all', '--log-filter-scopes', '+prop_read',
    ...(withArgs ? ['--log-filter-scopes', '+prop_arg'] : []),
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
    if (!line.includes('prop_read')) continue;
    const property = /property=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1];
    if (!property) continue;
    let name = property;
    if (name.startsWith('"')) {
        try { name = JSON.parse(name); } catch { name = name.slice(1, -1); }
    }
    // `scope=` is the log's own field (it says prop_read); the realm's url is
    // ours.
    const realm = /realm=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1] ?? '';
    const [member, argument] = splitArgument(name);
    reads.push({
        context: Number(/context=(\d+)/.exec(line)?.[1] ?? -1),
        realm: realm.startsWith('"') ? realm.slice(1, -1) : realm,
        seq: Number(/seq=(\d+)/.exec(line)?.[1] ?? -1),
        property: name,
        member,
        ...(argument === null ? {} : { argument }),
        occurrences: Number(/occurrences=(\d+)/.exec(line)?.[1] ?? 0),
    });
}

// `Window.matchMedia("(min-width: 100px)")` -> ['Window.matchMedia', '(min-width: 100px)'].
//
// The trailing group is anchored to the two shapes the engine emits -- a quoted
// string or a number -- rather than to "the last parenthesis", which an
// interface with no Meta.name would trip over: its Zig type name carries
// parens of its own, and a media query carries parens inside the argument.
function splitArgument(name) {
    const m = /^(.*)\(("[\s\S]*"|-?[\d.][\deE+.-]*)\)$/.exec(name);
    if (!m) return [name, null];
    const raw = m[2];
    return [m[1], raw.startsWith('"') ? raw.slice(1, -1) : raw];
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

// With --args a member appears once per distinct argument, so the read count
// stops being the member count. Both are worth having: the first says how wide
// the questioning was, the second how much of our surface it touched.
row.args = withArgs;
row.members = [...new Set(reads.map((r) => r.member))].length;
if (withArgs) {
    row.arguments = [...new Set(reads.filter((r) => r.argument !== undefined).map((r) => r.member))]
        .sort()
        .map((member) => ({
            member,
            distinct: reads.filter((r) => r.member === member && r.argument !== undefined).length,
            calls: reads.filter((r) => r.member === member).reduce((n, r) => n + r.occurrences, 0),
        }))
        .sort((a, b) => b.distinct - a.distinct);
}

await fs.mkdir(path.dirname(outPath), { recursive: true });
await fs.writeFile(outPath, JSON.stringify(row, null, 2));
console.log(`${reads.length} keys / ${row.members} members read across ${row.interfaces.length} interfaces in ${row.contexts.length} contexts -> ${path.relative(repo, outPath)}`);
for (const a of (row.arguments ?? []).slice(0, 10)) console.log(`  ${a.member}  ${a.distinct} distinct / ${a.calls} calls`);
if (row.reading) console.log(`  ${row.reading.nodes} nodes  ${row.reading.href}`);
if (row.error) console.log(`  error: ${row.error}`);
