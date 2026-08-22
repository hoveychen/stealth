// Runs one engine at every commercial bot guard in sites.mjs and records, per
// station, whether the guard served the site or served a challenge.
//
//   node tools/fingerprint/antibot-sweep.mjs <lightpanda|chrome> [--out results/x.json]
//
// detector-sweep.mjs asks "did the page finish"; the collectors ask "is this
// value Chrome's". Neither answers the question a crawler actually has, because
// a detector that writes `isBot: true` in its own report costs nothing, while
// Cloudflare deciding the same thing costs the page. This sweep is the third
// question: does the door open.
//
// Two readings per station, and they are kept separate on purpose:
//
//   * the *document's* HTTP status, taken off Network.responseReceived. A
//     Cloudflare managed challenge is served as 403, so status alone separates
//     "served the site" from "served the interstitial" without parsing anything.
//     lightpanda's responseReceived carries no headers (src/cdp/domains/
//     network.zig, ResponseWriter), so `cf-mitigated` is not readable from
//     either column symmetrically and is deliberately not used.
//   * the guard's marks in the DOM (extractAntibot). A challenge that ends in a
//     200 by the time the settle expires -- the interstitial solving itself and
//     redirecting -- looks identical to a plain pass on status alone, and the
//     interstitial's own DOM is what tells the two apart.
//
// Both engines are driven over the same route, in the same run, minutes apart,
// because the one thing that moves a guard's verdict as much as the fingerprint
// is the IP asking. A pass measured from a residential address says nothing
// about the same binary from a datacenter one; what this sweep isolates is the
// engine, by holding the address fixed across the two columns.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep } from './cdp.mjs';
import { ANTIBOT, extractAntibot } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: antibot-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port] [--headed] [--window-size 1920,1080] [--only cf-] [--chrome-arg SWITCH]... [--trace [--attach-frames|--same-process]]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const outPath = path.resolve(repo, arg('--out', `tools/fingerprint/results/antibot-${engine}.json`));
const proxy = arg('--proxy', null);
const windowSize = arg('--window-size', '1920,1080');
// Substring filter, so one station can be re-run without walking fifteen.
const only = arg('--only', null);
// Overrides the station's own settle. A challenge that has not cleared by the
// time the default expires is either failing or slow, and those are different
// findings; raising this is how the two get told apart.
const settleOverride = arg('--settle', null);
const headed = process.argv.includes('--headed');
// One engine process per station instead of one per sweep. Needed because a
// station that wedges the page takes every station after it down with it: the
// first run of this sweep had pixiv time out on Runtime.evaluate and then
// reported six DataDome stations as `Page.navigate` timeouts that were never
// attempted. A cascade like that is indistinguishable in the output from six
// real refusals, which is the failure mode detector-sweep.mjs's header comment
// describes from the other direction.
const fresh = process.argv.includes('--fresh');
// Record every request and every console line, not just the document responses.
// What a challenge does is a conversation -- fetch the orchestrate script, POST
// the result back, reload -- and which turn of it is missing is the whole
// diagnosis. Off by default because it is per-station noise nobody wants in a
// fifteen-station snapshot.
const trace = process.argv.includes('--trace');
// Put Chrome's cross-origin iframes back in the page's renderer, so their
// requests reach the page session this sweep attaches to. Without it a
// challenge that does its real work inside a `challenges.cloudflare.com` iframe
// reports only the iframe's *document* request here: everything the widget
// fetches afterwards is an OOPIF's traffic on a session nobody attached to, and
// the trace reads as "Chrome never asked for this". That is not a small
// difference -- it made four Cloudflare endpoints look lightpanda-only, on an
// engine that has one process and therefore cannot hide them.
// Only meaningful with --trace, and only for chrome; it does change the
// browser's process model, so a verdict taken with it wants a verdict without
// it beside it.
const sameProcess = process.argv.includes('--same-process');
// The other way to see an out-of-process iframe's traffic, and the one to
// prefer: attach to the iframe's own target instead of taking site isolation
// away. --same-process answers the visibility question but changes the verdict
// while doing it -- headed Chrome clears this Cloudflare challenge 5/5 without
// it and 0/3 with it -- so it cannot be used to observe a run that passes.
const attachFrames = process.argv.includes('--attach-frames');
// Extra Chrome switches, repeatable, so a single launch flag can be isolated
// against the same station without editing this file. The reason it exists:
// `--headless=new` differs from a headed Chrome in four readings and one of
// them is the user agent saying `HeadlessChrome`, so
// `--chrome-arg --user-agent=<the headed string>` is the one-variable
// experiment that says whether the guard is reading that or something else.
const chromeArgs = process.argv.reduce((acc, a, i) => (
    a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
const PORT = Number(arg('--port', engine === 'chrome' ? 9336 : 9226));
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
if (ENDPOINT && engine !== 'chrome') {
    console.error('CDP_ENDPOINT only makes sense with the chrome engine');
    process.exit(2);
}

const stations = ANTIBOT.filter((s) => !only || s.name.includes(only));
if (stations.length === 0) {
    console.error(`--only ${only} matched no station`);
    process.exit(2);
}

// Drain both streams: an unread pipe fills at 64KB and blocks the engine's next
// write for good, which from here looks exactly like the site hanging it. See
// the same note in detector-sweep.mjs, where three sites were blamed for it.
const engineLog = [];
const keep = (d) => {
    engineLog.push(String(d));
    if (engineLog.length > 4000) engineLog.splice(0, 2000);
};

let proc, profile;
// The child's own exit, if it had one before we killed it.
let exit = null;
// Set by teardown, so the SIGKILL we send ourselves is not read as a crash.
let killed = false;
async function launch() {
    if (ENDPOINT) return;
    if (engine === 'chrome') {
        profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-antibot-'));
        proc = spawn(CHROME, [
            `--remote-debugging-port=${PORT}`,
            `--user-data-dir=${profile}`,
            '--no-first-run',
            '--no-default-browser-check',
            `--window-size=${windowSize}`,
            ...(sameProcess
                ? ['--disable-features=IsolateOrigins,site-per-process', '--disable-site-isolation-trials']
                : []),
            ...(headed ? [] : ['--headless=new']),
            ...(proxy ? [`--proxy-server=${proxy}`] : []),
            ...chromeArgs,
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
        proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
            'serve', '--host', '127.0.0.1', '--port', String(PORT),
            ...(proxy ? ['--http-proxy', proxy] : []),
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    }
    proc.stdout.on('data', keep);
    proc.stderr.on('data', keep);
    // A dead engine and a stuck one are the same reading from a CDP client:
    // `Runtime.evaluate` stops answering either way. pixiv and claude.ai were
    // both written down as stations that "wedge the engine" across three runs
    // for exactly that reason, and both were aborting -- one on an out-of-bounds
    // read in deliverIntersections, one on a stale PerformanceObserver pointer
    // (results/engine-wedge.md). Record the signal so the next one is not
    // mis-called.
    exit = null;
    killed = false;
    proc.on('exit', (code, signal) => {
        // Our own teardown kill is not a finding: reporting it turned every
        // healthy station into `CRASHED SIGKILL`, which is the same signal
        // going unread as before, only louder.
        if (!killed) exit = { code, signal };
    });
}

async function teardown() {
    killed = true;
    proc?.kill('SIGKILL');
    proc = undefined;
    if (profile) {
        await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
        profile = undefined;
    }
    // The port has to be free before the next launch binds it.
    if (!ENDPOINT) await sleep(600);
}

// A guard's answer is a *sequence* -- 403 interstitial, then the challenge
// script's own fetches, then maybe a 200 -- so every document response for the
// station is kept in order rather than only the last.
let docs = [];
let wire = [];
// Filled by --attach-frames: the sessions of Chrome's out-of-process iframes.
const frameSessions = new Set();
let pageSession = null;
// The connection, hoisted so a target that attaches mid-run can have its own
// domains switched on from the event handler.
let liveCdp = null;
const onEvent = (msg) => {
    const p = msg.params ?? {};
    // A target attached under --attach-frames is silent until its own domains
    // are on; the whole point of attaching is the traffic it carries.
    if (msg.method === 'Target.attachedToTarget' && attachFrames && p.sessionId) {
        frameSessions.add(p.sessionId);
        liveCdp?.send('Network.enable', { maxPostDataSize: 65536 }, p.sessionId).catch(() => { });
        liveCdp?.send('Runtime.enable', undefined, p.sessionId).catch(() => { });
        // Nested iframes are targets of the target, not of the page.
        liveCdp?.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, p.sessionId).catch(() => { });
        return;
    }
    const fromFrame = msg.sessionId !== undefined && msg.sessionId !== pageSession;
    // Which session an event arrived on is a reading in itself: it says the
    // request belongs to the challenge's own iframe rather than to the page.
    const push = (e) => wire.push(fromFrame ? { ...e, frame: true } : e);
    if (trace) {
        if (msg.method === 'Network.requestWillBeSent') {
            // The body of the `fo/` POST is the whole client-side half of a
            // Cloudflare challenge: the program that comes back is chosen by
            // what was posted. Taken off the CDP event rather than by wrapping
            // XHR in the page, because a guard that is deciding whether this is
            // a browser is exactly the wrong audience for a patched prototype.
            const body = p.request?.postData;
            push({
                ev: 'req', id: p.requestId, method: p.request?.method, url: p.request?.url, type: p.type,
                ...(body === undefined
                    ? (p.request?.hasPostData ? { postLen: -1 } : {})
                    : { postLen: body.length, post: body.slice(0, 300) }),
            });
        } else if (msg.method === 'Network.responseReceived') {
            push({ ev: 'res', id: p.requestId, status: p.response?.status, url: p.response?.url, type: p.type });
        } else if (msg.method === 'Network.loadingFinished') {
            // How big the reply was, not just that it came. A Cloudflare `fo/`
            // response *is* the VM program the client then runs -- its length
            // decides how much work the challenge asks for -- and the page-side
            // instruments can only see it after the engine has parsed it. This
            // is the same number off the wire, so the two can be cross-checked.
            push({ ev: 'done', id: p.requestId, len: p.encodedDataLength });
        } else if (msg.method === 'Network.loadingFailed') {
            push({ ev: 'fail', text: p.errorText, url: p.request?.url });
        } else if (msg.method === 'Runtime.consoleAPICalled') {
            push({
                ev: `console.${p.type}`,
                text: (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ').slice(0, 300),
            });
        } else if (msg.method === 'Runtime.exceptionThrown') {
            push({ ev: 'exception', text: (p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '').slice(0, 300) });
        }
    }
    if (msg.method !== 'Network.responseReceived') return;
    // The verdict reads the *page's* document chain. An attached iframe reports
    // its own document too, and letting those in would move `last` to whatever
    // the challenge widget last loaded -- so a run with --attach-frames would
    // score differently from the same run without it, for no reason but the
    // instrument.
    if (fromFrame) return;
    if (String(p.type ?? '').toLowerCase() !== 'document') return;
    docs.push({ url: p.response?.url, status: p.response?.status, mime: p.response?.mimeType });
};

// What the two readings add up to. Ordered most-specific first: an interstitial
// that has already redirected can leave a 200 behind, so the DOM marks are
// consulted before the status.
//
// `_cf_chl_opt` and the challenge-platform script are deliberately *not* enough
// on their own, which the first run of this sweep got wrong. Cloudflare's JS
// detections ride along on ordinary pages: a headed Chrome reads pixiv's real
// page, 311 nodes and its real title, with both marks set, and chatgpt serves
// the script to this engine while serving Chrome a page without it. Treating
// either as a block scored two served pages as challenges. What separates being
// stopped at the door from being watched on the way in is the interstitial's own
// title and DOM, or a document that never stops being a 4xx -- so the marks are
// reported either way (`jsDetect`) and only those two decide the verdict.
function verdict(station, r, documents) {
    const first = documents[0]?.status ?? null;
    const last = documents[documents.length - 1]?.status ?? null;
    const base = { first, last };
    if (!r) return { verdict: 'error', ...base };
    const cf = r.cf ?? {};
    const dd = r.dd ?? {};
    const px = r.px ?? {};
    const akamai = r.akamai ?? {};
    const jsDetect = !!(cf.chlOpt || cf.platformScript);
    const out = { ...base, jsDetect };
    if (cf.blocked) return { verdict: 'cf-blocked', ...out };
    if (cf.justAMoment || cf.challengeDom) return { verdict: 'cf-challenge', ...out };
    // `captcha-delivery.com` in the markup is DataDome's equivalent of
    // `_cf_chl_opt`: it rides along on pages that were served. leboncoin handed
    // this engine 1440 nodes of its real site, in French, with the mark set, and
    // scored as a challenge for it. DataDome's interstitial arrives as a 4xx and
    // *then* renders the captcha, so the refusal is the first document, not the
    // mark -- and `blockText` is the interstitial's own wording either way.
    if (dd.blockText || (dd.captchaDelivery && first !== null && first >= 400)) {
        return { verdict: 'datadome-challenge', ...out };
    }
    if (px.pressAndHold || px.captchaDom || (px.deniedTitle && px.refId)) {
        return { verdict: 'px-challenge', ...out };
    }
    // No interstitial. A 4xx/5xx document with nothing rendered over it is still
    // a refusal -- some guards answer a bare 403 with no page at all -- and an
    // empty document behind a 200 is the engine failing to render, not a pass.
    if (last !== null && last >= 400) return { verdict: `refused-${last}`, ...out };
    if (akamai.accessDenied && akamai.reference) return { verdict: 'akamai-denied', ...out };
    if (r.empty) return { verdict: 'empty-document', ...out };
    return { verdict: 'pass', ...out };
}

const snapshot = {
    engine,
    headed: ENDPOINT ? 'remote' : headed,
    endpoint: ENDPOINT,
    proxy,
    windowSize,
    startedAt: new Date().toISOString(),
    egress: null,
    version: null,
    stations: [],
};

try {
    // The address is half of any guard's decision, so record it in the snapshot
    // rather than in a shell scrollback nobody keeps. Taken from this host, not
    // through the engine: it is the route's property, and both columns share it.
    try {
        const trace = await (await fetch('https://www.cloudflare.com/cdn-cgi/trace')).text();
        snapshot.egress = Object.fromEntries(
            trace.trim().split('\n').map((l) => l.split('=')).filter((p) => p.length === 2),
        );
    } catch (e) {
        snapshot.egress = { error: String(e.message ?? e) };
    }

    // A session, and whatever had to be spawned under it. Called once for the
    // whole sweep, or once per station under --fresh.
    async function session() {
        await launch();
        let version = null;
        for (let i = 0; i < 120; i++) {
            try {
                version = await (await fetch(`${ENDPOINT ?? `http://127.0.0.1:${PORT}`}/json/version`)).json();
                break;
            } catch {
                await sleep(200);
            }
        }
        if (!version) throw new Error(`${engine} CDP never came up`);
        snapshot.version ??= version;

        const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
        liveCdp = cdp;
        cdp.on(onEvent);
        let sessionId;
        if (engine === 'chrome') {
            const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
            ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
        } else {
            // One page reused for every station: lightpanda rejects a second
            // concurrent browser context.
            ({ sessionId } = await newPage(cdp));
            await cdp.send('Runtime.enable', {}, sessionId);
        }
        // maxPostDataSize is what makes `request.postData` arrive on
        // requestWillBeSent at all; without it every POST reports only
        // hasPostData and the body has to be asked for after the fact, by which
        // time a challenge's request is long gone.
        await cdp.send('Network.enable', trace ? { maxPostDataSize: 65536 } : {}, sessionId);
        pageSession = sessionId;
        if (attachFrames) {
            await cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId)
                .catch(() => { /* lightpanda has one process and no OOPIFs */ });
        }
        const [w, h] = windowSize.split(',').map(Number);
        await cdp.send('Emulation.setDeviceMetricsOverride', {
            width: w, height: h, deviceScaleFactor: 1, mobile: false,
        }, sessionId);
        return { cdp, sessionId };
    }

    let live = fresh ? null : await session();

    for (const station of stations) {
        const row = { name: station.name, vendor: station.vendor, url: station.url, guards: station.guards };
        const started = Date.now();
        docs = [];
        wire = [];
        let reading = null;
        try {
            if (fresh) live = await session();
            const { cdp, sessionId } = live;
            const settleMs = settleOverride ? Number(settleOverride) : station.settleMs;
            row.settleMs = settleMs;
            await goto(cdp, sessionId, station.url, { settleMs });
            reading = await evaluate(cdp, sessionId, extractAntibot);
        } catch (e) {
            row.error = String((e && e.message) || e).slice(0, 200);
        } finally {
            if (fresh) {
                live?.cdp.close();
                live = null;
                await teardown();
            }
        }
        // Only the child's own death lands here -- see the `killed` guard on
        // the exit handler.
        if (exit) row.engineExit = exit;
        row.documents = docs.slice(0, 12);
        if (trace) row.wire = wire.slice(0, 400);
        Object.assign(row, verdict(station, reading, docs));
        if (reading) {
            row.title = reading.title;
            row.landedOn = reading.href;
            row.nodes = reading.nodes;
            row.textLength = reading.textLength;
            row.snippet = reading.text.replace(/\s+/g, ' ').slice(0, 200);
            row.marks = { ...reading.cf, ...reading.dd, ...reading.px, ...reading.akamai };
        }
        row.ms = Date.now() - started;
        snapshot.stations.push(row);
        console.log(
            `${String(row.ms).padStart(6)}ms ${station.name.padEnd(18)} ${String(row.verdict).padEnd(19)} ` +
            `doc=${row.first ?? '-'}${row.last !== row.first ? `->${row.last}` : ''} ` +
            `nodes=${String(row.nodes ?? '-').padStart(5)} ` +
            (row.engineExit ? `CRASHED ${row.engineExit.signal ?? `exit ${row.engineExit.code}`} ` : '') +
            `${row.error ? `ERR ${row.error}` : `"${(row.title ?? '').slice(0, 40)}"`}`,
        );
    }
    live?.cdp.close();
} finally {
    await teardown();
    snapshot.fresh = fresh;
    snapshot.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-60);
    const pass = snapshot.stations.filter((s) => s.verdict === 'pass').length;
    snapshot.summary = { stations: snapshot.stations.length, pass };
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`\n${pass}/${snapshot.stations.length} passed — wrote ${path.relative(repo, outPath)}`);
    process.exit(0);
}
