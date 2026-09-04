// E2: what does the page-level challenge reply to round 1, and does the reply
// differ between an arm that clears and an arm that gets demoted?
//
// E1 (results/cfsc-oracle-diff.md) put the first divergence at the *second*
// `fo/` telemetry POST: the oracle posts round 2 back to the page-level
// challenge and is handed a clearance form, while this engine posts round 2 to
// the Turnstile widget's own challenge instance and never returns. The branch is
// taken after round 1's response, so round 1's response is the datum -- and it
// is the one thing the trace cannot show, because lightpanda never emits
// `Network.dataReceived` and every `loadingFinished` reads `len: 0`.
//
// `Network.getResponseBody` is implemented on both engines (lightpanda captures
// every response body into the frame arena, see CDP.zig onHttpResponseData), so
// the bodies can be read directly and the instrumentation gap sidestepped
// entirely. This records, for every challenge-platform / challenges.cloudflare
// request on either arm:
//
//   the full request post body   (round 1's telemetry, byte for byte)
//   the full response body       (the program the server hands back)
//   the response headers         (cf-mitigated and friends live here)
//
// Bodies are kept whole in the JSON -- a 32KB program that is *nearly* the same
// on both arms is the interesting case, and a head/tail excerpt would hide it.
//
// usage:
//   node tools/fingerprint/cfsc-fo-diff.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, personaScaleFlags, sleep } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const has = (n) => process.argv.includes(n);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: cfsc-fo-diff.mjs <lightpanda|chrome> [--headed-ua] [--url u] [--settle ms] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9252' : '9253'));
const OUT = arg('--out', null);
const headedUa = has('--headed-ua');
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Anything on a challenge endpoint, plus the document itself: the document's
// body is how the interstitial's own parameters (cvId, chlApiSitekey, the ray)
// get in, and those decide which challenge id round 1 is posted under.
const INTERESTING = /challenge-platform|challenges\.cloudflare\.com|\/cloudflare-challenge/;

// Read the headed user agent off the browser rather than writing it down --
// same one-variable arm antibot-sweep builds for --headed-ua. It is a launch
// switch, so it costs a throwaway launch on a scratch port.
async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${PORT + 1}`,
        `--user-data-dir=${dir}`,
        '--no-first-run', '--no-default-browser-check', '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${PORT + 1}/json/version`)).json();
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

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE,
    userAgentOverride: null,
    exchanges: [],   // one per interesting request, request and response whole
    wire: [],        // every request, so ordering stays readable
    console: [],
    exceptions: [],
};

if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    state.userAgentOverride = await headedUserAgent();
    console.log(`--headed-ua: ${state.userAgentOverride}`);
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-fo-'))}`,
        '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080',
        '--headless=new',
        ...personaScaleFlags(),
        ...(state.userAgentOverride ? [`--user-agent=${state.userAgentOverride}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info')], { stdio: ['ignore', 'pipe', 'pipe'] });

const engineLog = [];
const keep = (d) => {
    engineLog.push(String(d));
    if (engineLog.length > 4000) engineLog.splice(0, 2000);
};
proc.stdout.on('data', keep);
proc.stderr.on('data', keep);

let cdp = null;
try {
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) { state.version = await r.json(); break; }
        } catch { /* not up */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId: pageSession } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // requestId is only unique within a session, and the widget's round 2 lands
    // in the widget's own target on Chrome, so the session is part of the key.
    const byId = new Map();
    const key = (sid, id) => `${sid ?? 'page'}|${id}`;

    // Bodies read mid-flight, keyed the same way, plus the in-flight reads so the
    // report can wait for them instead of racing the teardown it exists to beat.
    const pending = [];
    function grabBody(e) {
        pending.push(cdp.send('Network.getResponseBody', { requestId: e.id }, e.session ?? pageSession)
            .then((r) => {
                e.liveBody = r.base64Encoded
                    ? Buffer.from(r.body, 'base64').toString('latin1')
                    : r.body;
            })
            .catch((err) => { e.liveBodyErr = String(err.message ?? err); }));
    }

    cdp.on((msg) => {
        const p = msg.params ?? {};
        // A freshly attached target is silent until its own domains are on, and
        // the traffic it carries is the reason for attaching.
        if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
            cdp.send('Network.enable', { maxPostDataSize: 1048576 }, p.sessionId).catch(() => { });
            cdp.send('Runtime.enable', undefined, p.sessionId).catch(() => { });
            cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, p.sessionId).catch(() => { });
            return;
        }
        const sid = msg.sessionId;
        const frame = sid !== undefined && sid !== pageSession;
        switch (msg.method) {
            case 'Network.requestWillBeSent': {
                const url = String(p.request?.url ?? '');
                const e = {
                    session: sid, frame, id: p.requestId, url,
                    method: p.request?.method, type: p.type,
                    requestHeaders: p.request?.headers ?? null,
                    postData: p.request?.postData ?? null,
                    hasPostData: p.request?.hasPostData ?? false,
                };
                byId.set(key(sid, p.requestId), e);
                state.wire.push({ ev: 'req', frame, id: p.requestId, method: e.method, url, type: e.type,
                    postLen: e.postData?.length ?? (e.hasPostData ? -1 : 0),
                    // Per event, not per request: a Critical-CH restart reuses the
                    // requestId, so the only way to see which of the two carried
                    // the high-entropy hints is to keep both header sets.
                    hints: Object.keys(p.request?.headers ?? {}).filter((k) => /^sec-ch/i.test(k)).sort() });
                break;
            }
            case 'Network.responseReceived': {
                const e = byId.get(key(sid, p.requestId));
                if (e) {
                    e.status = p.response?.status;
                    e.mime = p.response?.mimeType;
                    e.responseHeaders = p.response?.headers ?? null;
                    e.responseUrl = p.response?.url;
                }
                state.wire.push({ ev: 'res', frame, id: p.requestId, status: p.response?.status,
                    url: String(p.response?.url ?? '') });
                break;
            }
            case 'Network.loadingFinished': {
                const e = byId.get(key(sid, p.requestId));
                if (e) {
                    e.encoded = p.encodedDataLength ?? 0;
                    e.finished = true;
                    // An arm that *clears* tears the widget iframe down the moment
                    // the interstitial is replaced, and the iframe's CDP session
                    // goes with it -- so the after-settle pass below answers
                    // "Session with given id not found" for exactly the exchanges
                    // the passing arm exists to show. Read those bodies while the
                    // session is still alive. The call is out-of-band CDP traffic;
                    // the page cannot observe it.
                    if (frame && INTERESTING.test(e.url)) grabBody(e);
                }
                state.wire.push({ ev: 'done', frame, id: p.requestId, encoded: p.encodedDataLength ?? 0 });
                break;
            }
            case 'Network.loadingFailed': {
                const e = byId.get(key(sid, p.requestId));
                if (e) e.failed = p.errorText;
                state.wire.push({ ev: 'fail', frame, id: p.requestId, text: p.errorText });
                break;
            }
            case 'Runtime.consoleAPICalled': {
                if (state.console.length < 300) {
                    const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
                    state.console.push(`${p.type}: ${text.slice(0, 300)}`);
                }
                break;
            }
            case 'Runtime.exceptionThrown':
                if (state.exceptions.length < 80) {
                    state.exceptions.push((p.exceptionDetails?.exception?.description
                        ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 240));
                }
                break;
        }
    });

    await cdp.send('Target.setAutoAttach',
        { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, pageSession).catch(() => { });
    for (const d of ['Runtime', 'Log', 'Page']) {
        await cdp.send(`${d}.enable`, undefined, pageSession).catch(() => { });
    }
    // maxPostDataSize is the difference between reading round 1's telemetry and
    // only being told it existed.
    await cdp.send('Network.enable', { maxPostDataSize: 1048576 }, pageSession).catch(() => { });

    await cdp.send('Page.navigate', { url: URL_ }, pageSession);
    await sleep(SETTLE);

    try {
        state.final = await cdp.send('Runtime.evaluate', {
            expression: `JSON.stringify({
                href: location.href,
                title: document.title,
                nodes: document.getElementsByTagName('*').length,
                clearance: /cf_clearance/.test(document.cookie),
                text: (document.body ? document.body.innerText : '').slice(0, 300),
            })`,
            returnByValue: true,
        }, pageSession).then((r) => JSON.parse(r.result?.value ?? 'null'));
    } catch (err) { state.final = { err: String(err.message ?? err) }; }

    // The bodies. Asked for after settle so a challenge that is still running
    // has finished writing them, and only for the endpoints that matter -- the
    // whole page's worth would be megabytes of framework JS.
    await Promise.all(pending);
    for (const [, e] of byId) {
        if (!INTERESTING.test(e.url)) continue;
        const rec = {
            url: e.url, method: e.method, type: e.type, frame: e.frame,
            status: e.status, mime: e.mime, failed: e.failed,
            encoded: e.encoded ?? null,
            postLen: e.postData?.length ?? (e.hasPostData ? -1 : 0),
            post: e.postData ?? null,
            requestHeaders: e.requestHeaders,
            responseHeaders: e.responseHeaders,
        };
        if (e.liveBody !== undefined) {
            rec.bodyLen = e.liveBody.length;
            rec.body = e.liveBody;
            rec.bodyLive = true;
        } else try {
            const r = await cdp.send('Network.getResponseBody', { requestId: e.id }, e.session ?? pageSession);
            const body = r.base64Encoded ? Buffer.from(r.body, 'base64').toString('latin1') : r.body;
            rec.bodyLen = body.length;
            rec.body = body;
        } catch (err) {
            rec.bodyErr = e.liveBodyErr ?? String(err.message ?? err);
        }
        state.exchanges.push(rec);
    }
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
state.engineLog = engineLog.join('').slice(-6000);

// --- report ---------------------------------------------------------------
const short = (u) => u
    .replace('https://www.scrapingcourse.com', '{sc}')
    .replace('https://challenges.cloudflare.com', '{cf}');

console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
for (const e of state.exchanges) {
    console.log(`  ${String(e.method).padEnd(4)} ${String(e.status ?? e.failed ?? '').padEnd(4)}`
        + ` post=${String(e.postLen).padStart(6)} body=${String(e.bodyLen ?? e.bodyErr ?? '?').padStart(7)}`
        + ` ${e.frame ? 'F' : ' '} ${short(e.url).slice(0, 110)}`);
}
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.exceptions.length) {
    console.log(`exceptions(${state.exceptions.length}): ${state.exceptions.slice(0, 5).join(' | ')}`);
}
if (state.error) console.log(`ERROR ${state.error}`);

if (OUT) {
    const out = path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT));
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(state, null, 1));
    console.log(`wrote ${out}`);
}
