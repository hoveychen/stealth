// When does the engine stop answering CDP, and what is it doing at that moment?
//
//   node tools/fingerprint/wedge-probe.mjs <url> [--port 9240] [--seconds 90]
//                                    [--ping-timeout 5000] [--sample]
//
// The station sweeps read a wedged engine as `timeout: Runtime.enable` after a
// 25s settle -- one number, taken once, 55 seconds after the navigation. That
// cannot tell "busy from the first paint" from "fine for 3 seconds and then
// gone", and the second shape is what the readings imply: ak-kohls passes at
// --settle 3000 and times out at --settle 25000, three times out of three.
//
// So ping instead of waiting. `Target.getTargets` never touches the page, and
// the engine serves one CDP connection per worker thread with the page's own
// JS on that same thread (src/server.zig, `while (true) cdp.tick()`), so the
// round-trip time IS the length of whatever synchronous work is in front of it.
// --sample attaches macOS `sample` the first time a ping misses its deadline,
// which puts the stack behind the stall in the same run rather than a later
// one that may wedge somewhere else.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, sleep, evaluate } from './cdp.mjs';
import { extractReach } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
// Output goes to results/, not next to the script: `here` is a tracked
// directory now and these rigs write tens of megabytes of engine log.
const outDir = path.join(here, 'results');
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i === -1 ? fallback : process.argv[i + 1];
};
const url = process.argv[2];
if (!url || url.startsWith('--')) {
    console.error('usage: wedge-probe.mjs <url> [--port 9240] [--seconds 90] [--ping-timeout 5000]\n//                                    [--sample] [--read [--settle 8000]]\n//                                    [--runtime-enable] [--quiet] [--log-file PATH]');
    process.exit(2);
}
const PORT = Number(arg('--port', 9240));
const seconds = Number(arg('--seconds', 90));
const pingTimeout = Number(arg('--ping-timeout', 5000));
const wantSample = process.argv.includes('--sample');
const bin = process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda');

// --quiet drops the engine's log entirely. Not cosmetic: a sample of a
// wedged engine on kohls had the busy thread at 100% in `writev`, and the
// engine writes hundreds of kilobytes of INFO over one of these pages, so
// "the page is slow" and "we are the slow reader of its log" have to be told
// apart before either is believed.
const quiet = process.argv.includes('--quiet');
const proc = spawn(bin, [
    'serve', '--host', '127.0.0.1', '--port', String(PORT),
    ...(quiet ? ['--log-level', 'error'] : []),
], { stdio: ['ignore', 'pipe', 'pipe'] });
// The whole log is kept in memory, not just a tail: the line that explains a
// wedge (the watchdog stall, the first ExecutionTerminated) is at the START of
// the cascade, and a 60-line tail is 60 copies of the consequence. Only what
// the JSON keeps is written by default -- one of these runs against a station
// can produce 70MB, and `results/` is a tracked directory. Pass --log-file to
// put the full thing somewhere of your choosing.
const engineLog = [];
const keep = (d) => { engineLog.push(String(d)); };
const logFile = arg('--log-file', null);
// Grep-ables worth having in the JSON whatever else is dropped: they are the
// difference between "slow" and "the engine hung up".
const LOG_KEEP = /watchdog stall|pending terminate|SIGSEGV|panic|ExecutionTerminated/;
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);
let exited = null;
proc.on('exit', (code, signal) => { exited = { code, signal }; });

// A ping with its own deadline. Cdp.send's timeout is a fixed 30s, which is
// longer than the whole curve we want, so drive the race here and leave the
// stale promise to reject into the void (it has a catch).
const ping = (cdp) => {
    const started = Date.now();
    return Promise.race([
        cdp.send('Target.getTargets').then(() => ({ ms: Date.now() - started, ok: true })),
        sleep(pingTimeout).then(() => ({ ms: Date.now() - started, ok: false })),
    ]);
};

const rows = [];
let sampled = null;
try {
    for (let i = 0; i < 60; i++) {
        try {
            const v = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
            rows.push({ note: `version ${v['Lightpanda-Version']}` });
            break;
        } catch { await sleep(250); }
    }
    if (rows.length === 0) throw new Error('engine never came up');

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    const t0 = Date.now();
    await cdp.send('Page.navigate', { url }, sessionId).catch((e) => {
        rows.push({ note: `Page.navigate rejected: ${e.message}` });
    });
    rows.push({ note: `navigate returned at +${Date.now() - t0}ms` });

    // --read fires the reading the detector sweep makes, once, after `--settle`
    // ms, and keeps pinging while it runs. Two of the twelve detectors
    // (deviceinfo, iphey) answer pings happily for 45 seconds and then wedge
    // the engine on `extractReach` -- so the page settling and the page being
    // READ are two different costs, and only the second one is reachable this
    // way. The promise is deliberately not awaited: the point is to watch.
    if (process.argv.includes('--read')) {
        const settle = Number(arg('--settle', 12000));
        // --runtime-enable is the one thing the detector sweep does that this
        // probe did not, and it is not free: with the domain on, the engine
        // pushes a consoleAPICalled for every console call the page makes. A
        // sample of one wedged engine had the busy thread at 100% in `writev`.
        if (process.argv.includes('--runtime-enable')) {
            await cdp.send('Runtime.enable', {}, sessionId);
            rows.push({ note: 'Runtime.enable sent' });
        }
        sleep(settle).then(() => {
            rows.push({ note: `read started at +${Date.now() - t0}ms` });
            console.log(`   read started at +${Date.now() - t0}ms`);
            return evaluate(cdp, sessionId, extractReach);
        }).then((r) => {
            rows.push({ note: `read returned nodes=${r?.nodes} text=${r?.textLength}` });
            console.log(`   read returned nodes=${r?.nodes}`);
        }).catch((e) => {
            rows.push({ note: `read failed: ${String(e.message ?? e).slice(0, 120)}` });
            console.log(`   read failed: ${String(e.message ?? e).slice(0, 120)}`);
        });
    }

    while (Date.now() - t0 < seconds * 1000 && !exited) {
        const at = Date.now() - t0;
        const r = await ping(cdp);
        rows.push({ at, ...r });
        console.log(`+${String(at).padStart(6)}ms ping ${r.ok ? `${String(r.ms).padStart(6)}ms` : `MISSED >${pingTimeout}ms`}`);
        if (!r.ok && wantSample && !sampled) {
            const out = path.join(outDir, `sample-${Date.now()}.txt`);
            // 10 seconds at 1ms; `sample` prints its own self-time table, so no
            // parser here (see the sample-ships-its-own-self-time-table note).
            const s = spawnSync('sample', [String(proc.pid), '10', '1', '-file', out], { encoding: 'utf8' });
            sampled = s.status === 0 ? out : `sample failed: ${s.status} ${s.stderr?.slice(0, 200)}`;
            rows.push({ note: `sampled at +${at}ms -> ${sampled}` });
            console.log(`   sampled -> ${sampled}`);
        }
        await sleep(1000);
    }
    if (exited) {
        rows.push({ note: `engine exited ${exited.signal ?? `code ${exited.code}`}` });
        console.log(`engine exited ${exited.signal ?? `code ${exited.code}`}`);
    }
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    const stem = path.join(outDir, `wedge-${new URL(url).hostname}-${seconds}s`);
    const lines = engineLog.join('').split('\n').filter(Boolean);
    await fs.writeFile(`${stem}.json`, JSON.stringify({
        url, bin, seconds, pingTimeout, rows, sampled,
        engineLogLines: lines.length,
        engineLogVerdictLines: lines.filter((l) => LOG_KEEP.test(l)),
        engineLogTail: lines.slice(-40),
    }, null, 2) + '\n');
    if (logFile) await fs.writeFile(path.resolve(logFile), lines.join('\n') + '\n');
    console.log(`wrote ${path.relative(repo, `${stem}.json`)}${logFile ? ` and ${logFile}` : ''}`);
    process.exit(0);
}
