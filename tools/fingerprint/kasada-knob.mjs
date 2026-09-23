// Bisect Kasada's verdict with a knob, on either arm.
//
//   node kasada-knob.mjs <lightpanda|chrome> --knob <name> [--knob-file MODULE]
//                        [--url U] [--runs N] [--port P]
//
// kasada-verdict.mjs answers "does this engine get a ticket". This answers
// "does *this one change* cost a ticket", by injecting a script into the
// challenge document before the guard runs and reading the same `x-kpsdk-r`
// off the `/tl` response.
//
// The knob carrier of choice is Chrome, not this engine: Chrome holds a ticket
// on both stations, so every knob starts from a pass and a lost ticket is a
// signal rather than noise. Breaking one family at a time in a browser that
// otherwise passes is the only way to learn which family the station weighs.
//
// Runtime.enable is never sent -- Kasada withholds clearance from a client that
// has -- so the knob reports nothing and the only reading is the wire.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';
import { headedUserAgent } from './fo-harness.mjs';
import { KNOBS as TABLE } from './kasada-knobs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
// `--knob-file <path>` merges a scratch module's `KNOBS` export on top of the
// checked-in table, exactly as cf-knob.mjs does, so a one-session dose sweep
// does not have to land in kasada-knobs.mjs -- two sessions have already
// collided on the cf table, one declaring a knob the other was deleting, which
// leaves it unimportable and reads as a knob that changed nothing.
const knobFile = arg('--knob-file', null);
const EXTRA = knobFile ? (await import(path.resolve(process.cwd(), knobFile))).KNOBS : {};
const KNOBS = { ...TABLE, ...EXTRA };
const runs = Number(arg('--runs', 1));
const basePort = Number(arg('--port', 9400));
const target = arg('--url', 'https://www.hyatt.com/');
const settle = Number(arg('--settle', 14000));
const knobName = arg('--knob', 'none');
const outPath = arg('--out', null);

// `a+b` runs both knobs in one document, so a reader knob can watch what a
// changer knob did to the payload in the same run.
const parts = knobName.split('+');
for (const p of parts) {
    if (!(p in KNOBS)) {
        console.error('unknown knob:', p, '\nknown:', Object.keys(KNOBS).join(', '));
        process.exit(2);
    }
}
// Each part gets its own scope. Every knob carries the same `const __send`
// preamble, so concatenating two of them into one scope is a redeclaration --
// a SyntaxError that throws the whole injected script away and leaves the run
// looking like a knob that changed nothing.
const knobSrc = parts.map((p) => `try { (() => {\n${KNOBS[p]}\n})(); } catch (e) {}`).join('\n');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// `zig-out`, not `zig-out-rel`: the release tree is not what `zig build`
// refreshes, so it goes stale silently and this tool then reports the verdict
// of whatever binary was left there. On 2026-09-22 the `zig-out-rel` copy here
// was three weeks old (2026-08-31, older than the relay chain itself) and it
// took `x-hyatt` 0/5 on `x-kpsdk-r` in the same minute the current build took
// 5/5 -- so every Kasada reading taken through this tool without LP_BIN set was
// a reading of August's engine, and the station has in fact been open for some
// time. Same fix in `kasada-fetch-guard.mjs`. Pin the binary explicitly
// (`LP_BIN=.pinned/lp-bNNN-x`) whenever a run has to be attributable.
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');
// Ask the browser for its user agent instead of writing the version down.
//
// This was a hardcoded `Chrome/151.0.0.0`. Chrome moved to 152 and the guards
// began refusing the mismatch: on 2026-09-10 `cf-verdict.mjs` -- same constant,
// same use -- read `served=false` on BOTH arms including its control, on a
// station `antibot-sweep chrome --headed-ua` passed in the same minute. Nothing
// in the code had changed; the reference arm moved on its own. A criterion tool
// that silently reads false on a passing station invalidates every knob measured
// through it.
//
// Lazily, because only the Chrome arm sends it and probing costs a browser
// launch. The probe throws rather than falling back to a constant -- a silent
// fallback is how this failed in the first place.
let UA = null;
async function chromeUserAgent() {
    if (UA === null) UA = await headedUserAgent(basePort + 900);
    return UA;
}

async function once(port) {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'b84-knob-'));
    const proc = engine === 'chrome'
        ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
            '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), `--user-agent=${await chromeUserAgent()}`],
        { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
            { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.resume();
    proc.stderr.resume();
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    const rec = { documents: [], tl: [], beacons: [] };
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        cdp.on((m) => {
            if (m.method === 'Network.requestWillBeSent') {
                const url = String(m.params.request.url || '');
                // The knob's only channel out: an image request whose query
                // string is the reading. Runtime.enable is off limits here.
                if (url.includes('__b84')) rec.beacons.push(url.slice(url.indexOf('__b84')));
                // The guard's own error channel. It wraps its code in try/catch
                // and reports there rather than letting anything reach
                // window.onerror, so this is the only sign from outside that it
                // threw at all.
                if (/cdndex|\/error/i.test(url)) rec.errorReports = (rec.errorReports || []).concat(url.slice(0, 160));
                if (url.endsWith('/tl')) {
                    // When the POST goes out, relative to the navigation. The
                    // guard's own clock is not reachable from here, and this is
                    // the only part of its schedule the server also sees.
                    rec.tl.push({
                        postLen: m.params.request.postData ? m.params.request.postData.length : null,
                        atMs: rec.t0 ? Date.now() - rec.t0 : null,
                    });
                }
                return;
            }
            if (m.method !== 'Network.responseReceived') return;
            const r = m.params.response;
            const url = String(r.url || '');
            if (m.params.type === 'Document') rec.documents.push(r.status + '@' + (rec.t0 ? Date.now() - rec.t0 : '?'));
            if (url.endsWith('/tl')) {
                const h = r.headers || {};
                const last = rec.tl[rec.tl.length - 1] || {};
                last.status = r.status;
                last.cr = h['x-kpsdk-cr'];
                last.r = h['x-kpsdk-r'];
            }
        });
        // Page.enable before addScriptToEvaluateOnNewDocument: without it Chrome
        // accepts the call and silently never runs the script, which reads as a
        // knob that changed nothing.
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Network.enable', { maxPostDataSize: 1 << 20 }, sessionId);
        if (knobSrc) {
            await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: knobSrc }, sessionId);
        }
        rec.t0 = Date.now();
        await cdp.send('Page.navigate', { url: target }, sessionId);
        await sleep(settle);
    } finally {
        cdp.close();
        proc.kill('SIGKILL');
        await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
    }
    return rec;
}

const station = new URL(target).hostname;
const all = [];
for (let i = 0; i < runs; i++) {
    const rec = await once(basePort + i);
    all.push(rec);
    const tl = rec.tl.find((t) => t.status !== undefined) || rec.tl[0];
    console.log(`${engine} ${station} knob=${knobName} run ${i + 1}: ` +
        `docs=${rec.documents.join('->') || '(none)'} ` +
        (tl ? `tl=${tl.status}@${tl.atMs}ms postLen=${tl.postLen} cr=${tl.cr} r=${tl.r ?? '(absent)'}` : 'tl=(no POST)') +
        ` beacons=${rec.beacons.length}` +
        ` errorReports=${(rec.errorReports || []).length}`);
    for (const e of (rec.errorReports || []).slice(0, 2)) console.log('    ERR ->', e);
    if (!outPath) for (const b of rec.beacons.slice(0, 6)) console.log('   ', decodeURIComponent(b).slice(0, 300));
}
if (outPath) {
    await fs.writeFile(outPath, JSON.stringify(all, null, 2));
    console.log('wrote', outPath);
}
