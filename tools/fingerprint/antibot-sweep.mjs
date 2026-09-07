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
//     This used to add that lightpanda's responseReceived carries no headers,
//     so `cf-mitigated` could not be read symmetrically. That is no longer
//     true: ResponseWriter in src/cdp/domains/network.zig writes the header
//     map, and a --trace-headers run at x-hyatt gets 17 response headers off
//     this engine's `res` event, the same count Chrome reports. Reading
//     `cf-mitigated` is now an open option rather than a blocked one; the
//     status column simply has not needed it yet.
//   * the guard's marks in the DOM (extractAntibot). A challenge that ends in a
//     200 by the time the settle expires -- the interstitial solving itself and
//     redirecting -- looks identical to a plain pass on status alone, and the
//     interstitial's own DOM is what tells the two apart.
//
// Same route also means the same CDP domains. A guard can see the inspector:
// Kasada withholds ks-canadagoose's clearance from any client that has sent
// Runtime.enable, headed Chrome included. Chrome answers Runtime.evaluate with
// the domain off and lightpanda does not, so the obvious setup -- enable it for
// the engine that needs it -- quietly compares an observed client against an
// unobserved one. Neither column has it on while the guard runs.
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
import {
    Cdp, newPage, goto, evaluate, assertPersonaParity, personaScaleFlags, pinPersonaMedia,
    PERSONA_DEVICE_SCALE_FACTOR, sleep,
} from './cdp.mjs';
import { ANTIBOT, extractAntibot } from './sites.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: antibot-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port] [--headed] [--headed-ua] [--profile-dir DIR] [--window-size 1920,1080] [--only cf-] [--chrome-arg SWITCH]... [--trace [--trace-headers] [--attach-frames|--same-process]]');
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
// A Chrome profile directory that survives the run, so cookies and history
// accumulate across sweeps. Without it every Chrome arm is a first-ever visit.
const profileDir = arg('--profile-dir', null) && path.resolve(arg('--profile-dir'));
const headed = process.argv.includes('--headed');
// One engine process per station instead of one per sweep. Needed because a
// station that wedges the page takes every station after it down with it: the
// first run of this sweep had pixiv time out on Runtime.evaluate and then
// reported six DataDome stations as `Page.navigate` timeouts that were never
// attempted. A cascade like that is indistinguishable in the output from six
// real refusals, which is the failure mode detector-sweep.mjs's header comment
// describes from the other direction.
const fresh = process.argv.includes('--fresh');
// A script to run before anything on each new document, via
// Page.addScriptToEvaluateOnNewDocument. This is how a candidate engine change
// gets tried against the live station before it is written in Zig: patch the
// surface from JS, see whether the verdict moves, and only then decide whether
// the engine should behave that way. Repeatable. Unlike Runtime.enable, the
// registration itself is not visible to the page -- only whatever the script
// does is -- but it is still an asymmetry between the arms, so a run that uses
// it is not a two-arm reading of stock behaviour.
const injects = process.argv.reduce((acc, a, i) => (
    a === '--inject' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
// Record every request and every console line, not just the document responses.
// What a challenge does is a conversation -- fetch the orchestrate script, POST
// the result back, reload -- and which turn of it is missing is the whole
// diagnosis. Off by default because it is per-station noise nobody wants in a
// fifteen-station snapshot.
const trace = process.argv.includes('--trace');
// Also record the header block of every request and every response. Separate
// from --trace because a guard's conversation is legible from the URLs alone
// and the headers multiply a station's trace by roughly ten; you want them only
// when the question has narrowed to one exchange. The question they answer is
// the one a body-only trace cannot: two arms that send the same POST to the same
// URL and get different verdicts differ either in what they sent *around* the
// body, or in the body. This settles the cheap half first.
const traceHeaders = process.argv.includes('--trace-headers');
// Pull the *body* back for responses whose URL contains one of these, via
// Network.getResponseBody. Repeatable. A guard's verdict is often in the reply
// it sends the challenge program rather than in the status line -- Kasada's
// /tl answers 200 to a client it is about to refuse -- and the sweep otherwise
// records only that reply's length. The call is client-to-browser, so the page
// cannot see it happen.
//
// Two things a reader of the result has to know. An empty `body` can be the
// answer rather than a miss: Kasada's refusal to this engine at x-hyatt is a
// 200 with `content-length: 0`, and the capture reporting nothing there is it
// working. And Chrome loses a body to any navigation in the same tick -- it
// flushes the resource buffer on commit, so the reply that *clears* a challenge
// is exactly the one that tends to come back `-32000 No resource`, because
// clearing it is what makes the page navigate. Read the reply's headers, which
// --trace-headers keeps either way.
const traceBodies = process.argv.reduce((acc, a, i) => (
    a === '--trace-body' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
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
// The other way to see an out-of-process iframe's traffic: attach to the
// iframe's own target instead of taking site isolation away. --same-process
// answers the visibility question but changes the verdict while doing it --
// headed Chrome clears this Cloudflare challenge 5/5 without it and 0/3 with it.
//
// This one used to be described here as the safe alternative, and it is not.
// On x-hyatt a headed Chrome passes with plain --trace and is refused 429 with
// --trace --attach-frames, measured back to back in one sitting. Kasada can see
// the attachment. So neither flag is free: reach for --trace alone first, and
// only add this when the traffic you need is genuinely inside an out-of-process
// frame, knowing the verdict beside it is no longer the browser's own.
const attachFrames = process.argv.includes('--attach-frames');
// Extra Chrome switches, repeatable, so a single launch flag can be isolated
// against the same station without editing this file. The reason it exists:
// `--headless=new` differs from a headed Chrome in four readings and one of
// them is the user agent saying `HeadlessChrome`, so
// `--chrome-arg --user-agent=<the headed string>` is the one-variable
// experiment that says whether the guard is reading that or something else.
const chromeArgs = process.argv.reduce((acc, a, i) => (
    a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
// That experiment has been run, and the word is worth seven stations. Measured
// 2026-08-22, three arms in one sitting from one address: plain headless 2/15,
// headless with the headed user agent 9/15, headed 10/15 -- and the two
// nine-and-ten arms agree on fourteen of the fifteen stations. So the reference
// that clears a Cloudflare managed challenge does not have to be a headed
// browser, which is what makes it usable as an oracle: it runs anywhere this
// sweep does. This flag is that arm in one word.
//
// Off by default: the whole point of a snapshot is knowing which browser it
// describes, and `antibot-chrome-headless.json` files predate this. The arm a
// run took is recorded in the snapshot header instead.
//
// The string is not hardcoded. Chrome's user agent is version-reduced
// (`Chrome/151.0.0.0`) and platform-specific, and composing it here would be
// reimplementing that reduction from memory; the browser's own answer, with the
// one token swapped, is the same string a headed launch reports -- verified by
// reading /json/version from both.
const headedUa = process.argv.includes('--headed-ua');
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

// The headed user agent, read off the browser rather than written down. A
// throwaway launch on a scratch port, because --user-agent is a launch switch:
// by the time /json/version can be asked, the browser is already the arm it is
// going to be. Only paid when --headed-ua is on.
async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const port = PORT + 1;
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${port}`,
        `--user-data-dir=${dir}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent for --headed-ua');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

let proc, profile;
// The child's own exit, if it had one before we killed it.
let exit = null;
// Set by teardown, so the SIGKILL we send ourselves is not read as a crash.
let killed = false;
async function launch() {
    if (ENDPOINT) return;
    if (engine === 'chrome') {
        // A named profile is kept across launches; the default one is a fresh
        // mkdtemp that teardown deletes. That default is not neutral: a Chrome
        // with no cookie and no history is challenged by every DataDome station
        // measured, including ones this engine walks into, so the reference
        // column cannot tell "the engine is detected" from "this scratch
        // profile is" (README, B89). Warming a profile is how that column is
        // made to mean something.
        profile = profileDir
            ? (await fs.mkdir(profileDir, { recursive: true }), profileDir)
            : await fs.mkdtemp(path.join(os.tmpdir(), 'fp-antibot-'));
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
            ...(userAgentOverride ? [`--user-agent=${userAgentOverride}`] : []),
            ...personaScaleFlags(chromeArgs),
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
    // SIGKILL costs a named profile everything it just learned: Chrome keeps
    // cookies in memory and writes the sqlite store on a graceful shutdown, so
    // a killed browser leaves the file created and empty -- which reads exactly
    // like a station that set no cookie. Measured: one run against dd-hermes
    // under SIGKILL persisted 0 cookies. Ask politely first when the profile is
    // meant to survive, and keep the immediate kill otherwise so an ordinary
    // sweep pays nothing.
    if (proc && profileDir) {
        const dead = new Promise((resolve) => proc.once('exit', resolve));
        proc.kill('SIGTERM');
        await Promise.race([dead, sleep(5000)]);
    }
    proc?.kill('SIGKILL');
    proc = undefined;
    if (profile) {
        // Deleting a named profile would throw away the very thing it exists to
        // accumulate.
        if (!profileDir) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
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
// The zero for `--trace` timestamps, reset per station.
let stationStarted = Date.now();
// requestId -> url, for the responses --trace-body matched: the body can only
// be asked for once loadingFinished says the transfer is complete, and by then
// the event carrying the URL is gone.
let bodyWanted = new Map();
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
        // Detectable, and a challenge often lives in exactly this iframe -- see
        // the note at the station loop. --attach-frames is a diagnostic mode, so
        // it buys the frame's events at the price of a verdict worth less.
        liveCdp?.send('Runtime.enable', undefined, p.sessionId).catch(() => { });
        // Nested iframes are targets of the target, not of the page.
        liveCdp?.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, p.sessionId).catch(() => { });
        return;
    }
    const fromFrame = msg.sessionId !== undefined && msg.sessionId !== pageSession;
    // Which session an event arrived on is a reading in itself: it says the
    // request belongs to the challenge's own iframe rather than to the page.
    // Every trace entry is stamped, relative to the station's own start. A
    // guard's sensor reports how long its collection took inside its payload --
    // Akamai's `sensor_data` header carries it in cleartext -- and the only way
    // to tell that number apart from a counter is to have the wall clock beside
    // it. Relative rather than absolute because what a reader wants is "the
    // POST left 650ms after the document arrived", not two epoch timestamps to
    // subtract by hand.
    const push = (e) => wire.push({ ...(fromFrame ? { ...e, frame: true } : e), ms: Date.now() - stationStarted });
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
                ...(traceHeaders ? { headers: p.request?.headers ?? null } : {}),
            });
        } else if (msg.method === 'Network.responseReceived') {
            push({
                ev: 'res', id: p.requestId, status: p.response?.status, url: p.response?.url, type: p.type,
                ...(traceHeaders ? { headers: p.response?.headers ?? null, resProto: p.response?.protocol ?? null } : {}),
            });
            const url = p.response?.url ?? '';
            if (traceBodies.some((m) => url.includes(m))) bodyWanted.set(p.requestId, url);
        } else if (traceHeaders && msg.method === 'Network.requestWillBeSentExtraInfo') {
            // Chrome's requestWillBeSent carries only what the renderer set.
            // Cookie, Accept-Encoding, Accept-Language, Sec-Fetch-*, Origin and
            // Content-Length are added afterwards by the network service and
            // appear only here. lightpanda has one stack and reports the final
            // set on requestWillBeSent, so comparing the two arms on that event
            // alone reads Chrome's provisional block against this engine's wire
            // block and invents a dozen headers Chrome does in fact send.
            push({ ev: 'reqxi', id: p.requestId, headers: p.headers ?? null });
        } else if (traceHeaders && msg.method === 'Network.responseReceivedExtraInfo') {
            // The response side of the same asymmetry: Set-Cookie is stripped
            // out of responseReceived and delivered only here.
            push({ ev: 'resxi', id: p.requestId, status: p.statusCode, headers: p.headers ?? null });
        } else if (msg.method === 'Network.loadingFinished') {
            // How big the reply was, not just that it came. A Cloudflare `fo/`
            // response *is* the VM program the client then runs -- its length
            // decides how much work the challenge asks for -- and the page-side
            // instruments can only see it after the engine has parsed it. This
            // is the same number off the wire, so the two can be cross-checked.
            //
            // Within one arm. NOT across the two: `encodedDataLength` is each
            // engine's own accounting, and the two do not agree on what to
            // count. At x-hyatt both arms are served a byte-identical 429 --
            // same header set, `content-length: 495` against `496`, the one
            // byte being the token -- and this field reports 1475 for Chrome
            // and 1882 for lightpanda. A trace that reads those two numbers as
            // "the guard served us a different interstitial" is reading the
            // instrument. Compare `content-length` off --trace-headers instead.
            push({ ev: 'done', id: p.requestId, len: p.encodedDataLength });
            const wanted = bodyWanted.get(p.requestId);
            if (wanted !== undefined) {
                bodyWanted.delete(p.requestId);
                // Fire and forget: the entry lands in `wire` whenever the reply
                // comes, and the station's settle is long enough that it always
                // does. Awaiting here would stall the event stream.
                const entry = { ev: 'body', id: p.requestId, url: wanted, ms: Date.now() - stationStarted };
                wire.push(entry);
                liveCdp?.send('Network.getResponseBody', { requestId: p.requestId }, msg.sessionId)
                    .then((r) => { entry.body = r?.body ?? null; entry.base64 = r?.base64Encoded ?? false; })
                    .catch((e) => { entry.bodyError = String(e?.message ?? e); });
            }
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
/// Is this engine still there? `Target.getTargets` touches no page, and the
/// answer has to come back on a deadline of its own: Cdp.send waits 30 seconds,
/// which is longer than the stall it is being asked about. A closed socket
/// throws on the way out, which is the fast no.
async function answersPing(live) {
    if (!live) return false;
    try {
        return await Promise.race([
            live.cdp.send('Target.getTargets').then(() => true),
            sleep(5000).then(() => false),
        ]);
    } catch {
        return false;
    }
}

function verdict(station, r, documents) {
    const first = documents[0]?.status ?? null;
    const last = documents[documents.length - 1]?.status ?? null;
    const base = { first, last };
    if (!r) return { verdict: 'error', ...base };
    const cf = r.cf ?? {};
    const dd = r.dd ?? {};
    const px = r.px ?? {};
    const akamai = r.akamai ?? {};
    const kasada = r.kasada ?? {};
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
    // Kasada is deliberately *not* judged here, only recorded. Its marks ride
    // along on pages it served: headed Chrome came back from canadagoose with
    // `429 -> 200`, 1849 nodes of the real storefront and its real title, and
    // `window.KPSDK` still defined — the SDK stays loaded once it has let you
    // in. A rule on the marks scored that pass as a challenge. This is the same
    // trap the DataDome comment above describes, and the reason its rule needs
    // the first document to be a 4xx. Kasada does not need even that: an
    // unsolved interstitial is 681 bytes with no text, which `empty` and the
    // status rule below already catch between them.
    // No interstitial. A 4xx/5xx document with nothing rendered over it is still
    // a refusal -- some guards answer a bare 403 with no page at all -- and an
    // empty document behind a 200 is the engine failing to render, not a pass.
    if (last !== null && last >= 400) return { verdict: `refused-${last}`, ...out };
    if (akamai.accessDenied && akamai.reference) return { verdict: 'akamai-denied', ...out };
    if (r.empty) return { verdict: 'empty-document', ...out };
    return { verdict: 'pass', ...out };
}

// Resolved before the first launch when --headed-ua is on, and recorded in the
// header: two snapshots that differ only in this are two different browsers.
if (profileDir && engine !== 'chrome') {
    console.error('--profile-dir only makes sense with the chrome engine');
    process.exit(2);
}
let userAgentOverride = null;
if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    userAgentOverride = await headedUserAgent();
    console.log(`--headed-ua: ${userAgentOverride}`);
}

const snapshot = {
    engine,
    headed: ENDPOINT ? 'remote' : headed,
    endpoint: ENDPOINT,
    proxy,
    windowSize,
    chromeArgs,
    userAgentOverride,
    // What the arm actually answered for each persona axis, filled in once the
    // page exists. Recorded so a snapshot can never be compared with one taken
    // on a different scale or theme without that being visible in the file.
    personaAxes: null,
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
        // The scale here has to agree with the launch switch, or it undoes it:
        // Chrome honours this parameter and would be pulled back to 1, which is
        // exactly the mismatch that made this engine's readings look wrong (see
        // PERSONA_DEVICE_SCALE_FACTOR in cdp.mjs). This engine ignores the
        // parameter either way, so it keeps the 1 that costs it no
        // `not_implemented` warning -- the value only ever moves Chrome.
        await cdp.send('Emulation.setDeviceMetricsOverride', {
            width: w,
            height: h,
            deviceScaleFactor: engine === 'chrome' ? PERSONA_DEVICE_SCALE_FACTOR : 1,
            mobile: false,
        }, sessionId);

        // The theme, which no launch switch carries and which a headless Chrome
        // inherits from a host that may change it by the hour. Then read every
        // axis back and refuse the sweep outright on an arm that is not on the
        // persona: a station's verdict compared across mismatched arms is not a
        // comparison, and a sweep that reports rows anyway is worse than one
        // that stops.
        await pinPersonaMedia(cdp, sessionId);
        snapshot.personaAxes = await assertPersonaParity(cdp, sessionId, { label: engine });

        if (injects.length) {
            // Chrome answers Page.addScriptToEvaluateOnNewDocument with an
            // identifier whether or not the Page domain is on, and only *runs*
            // the script if it is: without this line the registration is
            // accepted and silently never fires, so an --inject run against the
            // Chrome arm measures stock Chrome while reporting itself as
            // patched. Verified both ways at scratch/b55-inject-check.mjs --
            // window marker MISSING without the enable, present with it.
            // Enabled for both engines even though lightpanda's registration
            // takes without it, because the arms have to carry the same domains:
            // a guard can see the inspector, and --inject runs are compared
            // against each other.
            await cdp.send('Page.enable', {}, sessionId).catch(() => { /* older engine */ });
            for (const f of injects) {
                await cdp.send('Page.addScriptToEvaluateOnNewDocument',
                    { source: await fs.readFile(path.resolve(repo, f), 'utf8') }, sessionId);
            }
        }
        return { cdp, sessionId };
    }

    let live = fresh ? null : await session();

    for (const station of stations) {
        const row = { name: station.name, vendor: station.vendor, url: station.url, guards: station.guards };
        const started = Date.now();
        stationStarted = started;
        docs = [];
        wire = [];
        bodyWanted = new Map();
        let reading = null;
        try {
            if (fresh) live = await session();
            const { cdp, sessionId } = live;
            const settleMs = settleOverride ? Number(settleOverride) : station.settleMs;
            row.settleMs = settleMs;
            // Runtime has to be off while the guard runs, in both columns. The
            // domain is detectable: Kasada withholds the x-kpsdk-r that clears
            // ks-canadagoose from any client that has enabled it, headed Chrome
            // included -- the same binary passes the station seconds later with
            // the domain left alone. Chrome answers Runtime.evaluate anyway, so
            // it never needed it; lightpanda does need it, and enabling it
            // before the navigation is what made the two columns disagree about
            // this station for most of a month. Enable it after the settle,
            // read the page, and put it back.
            if (engine === 'lightpanda') {
                await cdp.send('Page.navigate', { url: station.url }, sessionId);
                await sleep(settleMs);
                await cdp.send('Runtime.enable', {}, sessionId);
            } else {
                await goto(cdp, sessionId, station.url, { settleMs });
            }
            reading = await evaluate(cdp, sessionId, extractAntibot);
            if (engine === 'lightpanda') await cdp.send('Runtime.disable', {}, sessionId);
        } catch (e) {
            row.error = String((e && e.message) || e).slice(0, 200);
        } finally {
            if (fresh) {
                live?.cdp.close();
                live = null;
                await teardown();
            }
        }
        // One station's stall must not cost the stations after it. A 30-second
        // tick in this engine ends the whole CDP connection --
        // `watchdog stall` -> `env.requestTerminate()` -> CDP.tick sends
        // CLOSE_GOING_AWAY (`reason="pending terminate"`) -- so the socket is
        // gone and every station after the culprit reads as a timeout of its
        // own. That is the "one crash and its tail" shape in the archived
        // sweeps, and it is why five of twenty-nine stations could not be
        // measured at all. Rebuild the session when a row errored and the
        // engine has stopped answering, and mark the row: a sweep that
        // restarted mid-run is not the same reading as one that did not.
        if (!fresh && row.error && !(await answersPing(live))) {
            row.engineRestarted = true;
            live?.cdp.close();
            live = null;
            await teardown();
            live = await session();
        }
        // Only the child's own death lands here -- see the `killed` guard on
        // the exit handler.
        if (exit) row.engineExit = exit;
        row.documents = docs.slice(0, 12);
        // 400 was not enough for a station that loops. Akamai's interstitial
        // re-runs its whole conversation on every reload, and one lightpanda
        // run through macys spent 154 of the first 400 entries on the sensor's
        // `chrome-extension://` probe list alone -- so the cycle that mattered,
        // the second one, was cut off.
        if (trace) row.wire = wire.slice(0, 1200);
        Object.assign(row, verdict(station, reading, docs));
        if (reading) {
            row.title = reading.title;
            row.landedOn = reading.href;
            row.nodes = reading.nodes;
            row.textLength = reading.textLength;
            row.snippet = reading.text.replace(/\s+/g, ' ').slice(0, 200);
            row.marks = { ...reading.cf, ...reading.dd, ...reading.px, ...reading.akamai, ...reading.kasada };
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
    // Two snapshots that differ only in whether the profile was warm are two
    // different reference arms; the door map is not comparable across them.
    snapshot.profileDir = profileDir;
    snapshot.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-60);
    const pass = snapshot.stations.filter((s) => s.verdict === 'pass').length;
    snapshot.summary = { stations: snapshot.stations.length, pass };
    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, JSON.stringify(snapshot, null, 2) + '\n');
    console.log(`\n${pass}/${snapshot.stations.length} passed — wrote ${path.relative(repo, outPath)}`);
    process.exit(0);
}
