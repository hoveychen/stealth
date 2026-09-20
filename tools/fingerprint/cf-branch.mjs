// Where Cloudflare's challenge actually forks, read off the exchange instead of
// off whether the station served the page.
//
//   node tools/fingerprint/cf-branch.mjs <lightpanda|chrome>[:headed-ua|:headed]
//   node tools/fingerprint/cf-branch.mjs --arms lightpanda,chrome:headed --pairs 3
//        [--url u] [--settle ms] [--port n] [--out path]
// env: LP_BIN, CHROME
//
// `:headed-ua` is a headless Chrome wearing the headed UA string, and
// `--user-agent` blanks every client hint, so its request shape is not a real
// browser's (`ua-override-blanks-client-hints`). `:headed` is a real window.
// On this criterion the two read the same -- measured 2026-09-20 over 3 station-
// level alternated triples, `branch=clear` and `served=true` 3/3 on BOTH Chrome
// arms against 0/3 here -- so no earlier cf comparison run against `:headed-ua`
// is void on account of its reference arm. Prefer `:headed` anyway when the
// thing being compared is request-side.
//
// `served=` is the criterion this repo trusts, and it is also a 1-in-6 lottery:
// a clean Chrome drops a ticket every sixth run, so only `0/N` ever refutes
// anything (`cfsc-verdict-is-five-in-six`). `cf-chl-out` is worse -- a token
// Cloudflare hands out and then declines to honour (`cf-ticket-is-not-a-pass`).
// The token blob length used to separate the arms and no longer does: measured
// 2026-09-20 both arms read edge 57 / widget 68 blocks with no jitter at all,
// while `served=` still split 3/3 against 0/3.
//
// This does not beat the lottery, and the first draft of this comment claimed it
// did on the strength of three Chrome runs that all happened to win. Measured
// over 12 runs the same day, `branch` and `served=` agree 12 times out of 12 --
// including the Chrome run that dropped its ticket, where `branch` said `retry`.
// It is a faithful proxy, not a quieter one.
//
// What it buys instead is *where*. The fork is the response to the THIRD `fo/`
// post, it lands about half a minute before the verdict, and it is not a
// response to a different request -- both arms send essentially the same bytes
// there. Cloudflare simply answers them differently:
//
//   chrome --headed-ua   post ~89K  ->  text/html  ~7K    PAGE WIDGET WIDGET PAGE
//   lightpanda           post ~89K  ->  text/plain ~43K   PAGE WIDGET WIDGET
//
// Only the arm handed the form goes on to make the fourth post -- back to the
// page-level challenge, the last thing that happens before the page is served.
// This engine never makes it, because it is never asked to: over 9 runs it drew
// `clear` zero times and made the fourth post zero times.
//
// So the reading is the third post's response kind:
//
//   branch=clear   text/html   the fork was taken the way a passing arm takes it
//   branch=retry   text/plain  handed another round instead
//   branch=none                fewer than three posts happened at all
//
// Deliberately NOT done: reading any response body, and injecting anything into
// the page. Both are affordable here and both have burned this repo before --
// an instrument that leaves text in the realm can open the station by itself
// (`instruments-that-leave-text-open-cf`). Request metadata is enough.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Cdp, personaScaleFlags, sleep, assertPersonaParity, pinPersonaMedia } from './cdp.mjs';
import { arg, CHROME, LIGHTPANDA, headedUserAgent } from './fo-harness.mjs';

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const BASE_PORT = Number(arg('--port', '9292'));
const PAIRS = Number(arg('--pairs', '1'));
const OUT = arg('--out', null);

// An arm is `<engine>` or `<engine>:headed-ua`; `--arms` takes a comma list.
// The alternation it drives is station-level -- one run of each arm, then the
// next pair -- because a station that hardens with each visit gives the arm
// that ran first a window the other one never sees (`block-ab-biases-the-second-arm`).
const ARMS = (arg('--arms', null) ?? process.argv[2] ?? '').split(',').filter(Boolean);
if (!ARMS.length || ARMS.some((a) => !/^(lightpanda|chrome)(:headed-ua|:headed)?$/.test(a))) {
    console.error('usage: cf-branch.mjs <lightpanda|chrome>[:headed-ua|:headed] [--out p]');
    console.error('       cf-branch.mjs --arms lightpanda,chrome:headed --pairs 3');
    process.exit(2);
}

// The document itself is in the filter only so a run that never reaches the
// challenge at all is distinguishable from one whose posts went missing.
const FO = /\/cdn-cgi\/challenge-platform\/[^?]*\/fo\//;

/// Which challenge instance a post went to. The page-level challenge lives on
/// the station's own origin; the widget runs its own instance on Cloudflare's.
const sideOf = (url) => (/challenges\.cloudflare\.com/.test(url) ? 'WIDGET' : 'PAGE');

/// The reading. `text/html` is the clearance form, anything else is another
/// round -- keyed on the mime rather than on the length, because the length of
/// the retry program moves between windows and the kind does not.
function branchOf(posts) {
    if (posts.length < 3) return 'none';
    return /html/.test(String(posts[2].mime ?? '')) ? 'clear' : 'retry';
}

async function runOnce(arm, port) {
    const engine = arm.split(':')[0];
    const headedUa = arm.endsWith(':headed-ua');
    // `:headed` is a real browser window, not a headless one wearing a headed
    // UA string. `--user-agent` blanks every client hint, so `:headed-ua` does
    // not have this engine's request shape -- comparing anything request-side
    // against it reads a difference that is the flag's, not the engine's
    // (`ua-override-blanks-client-hints`, `cf-mdrd-length-is-a-request-shape-probe`).
    const headed = arm.endsWith(':headed');
    const state = {
        arm, engine, url: URL_, settleMs: SETTLE, headedUa, headed,
        userAgentOverride: null, posts: [], exceptions: [],
    };

    if (headedUa) state.userAgentOverride = await headedUserAgent(port + 1);

    let profile;
    const proc = engine === 'chrome'
        ? spawn(CHROME, [
            `--remote-debugging-port=${port}`,
            `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-br-'))}`,
            '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080',
            ...(headed ? [] : ['--headless=new']),
            ...personaScaleFlags(),
            ...(state.userAgentOverride ? [`--user-agent=${state.userAgentOverride}`] : []),
        ], { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(port),
            '--log_level', arg('--log-level', 'info')], { stdio: ['ignore', 'pipe', 'pipe'] });

    const engineLog = [];
    const keep = (d) => { engineLog.push(String(d)); if (engineLog.length > 2000) engineLog.splice(0, 1000); };
    proc.stdout.on('data', keep);
    proc.stderr.on('data', keep);

    let cdp = null;
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const r = await fetch(`http://127.0.0.1:${port}/json/version`);
                if (r.ok) { state.version = await r.json(); break; }
            } catch { /* not up */ }
            await sleep(250);
        }

        cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId: pageSession } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

        // requestId is unique per session, and the widget's posts land in the
        // widget's own target on Chrome, so the session is part of the key.
        const byId = new Map();
        const key = (sid, id) => `${sid ?? 'page'}|${id}`;

        cdp.on((msg) => {
            const p = msg.params ?? {};
            // A freshly attached target is silent until its own domains are on,
            // and the traffic it carries is the whole reason for attaching.
            if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
                cdp.send('Network.enable', { maxPostDataSize: 1048576 }, p.sessionId).catch(() => { });
                cdp.send('Runtime.enable', undefined, p.sessionId).catch(() => { });
                cdp.send('Target.setAutoAttach',
                    { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, p.sessionId).catch(() => { });
                return;
            }
            const sid = msg.sessionId;
            switch (msg.method) {
                case 'Network.requestWillBeSent': {
                    const url = String(p.request?.url ?? '');
                    if (!FO.test(url)) return;
                    const e = {
                        seq: state.posts.length, side: sideOf(url), url,
                        method: p.request?.method,
                        // -1 says "there was a body and CDP would not show it",
                        // which is a different failure from a body of zero.
                        postLen: p.request?.postData?.length ?? (p.request?.hasPostData ? -1 : 0),
                    };
                    byId.set(key(sid, p.requestId), e);
                    state.posts.push(e);
                    break;
                }
                case 'Network.responseReceived': {
                    const e = byId.get(key(sid, p.requestId));
                    if (!e) return;
                    e.status = p.response?.status;
                    e.mime = p.response?.mimeType;
                    break;
                }
                case 'Network.loadingFinished': {
                    const e = byId.get(key(sid, p.requestId));
                    if (e) e.encoded = p.encodedDataLength ?? 0;
                    break;
                }
                case 'Network.loadingFailed': {
                    const e = byId.get(key(sid, p.requestId));
                    if (e) e.failed = p.errorText;
                    break;
                }
                case 'Runtime.exceptionThrown':
                    if (state.exceptions.length < 40) {
                        state.exceptions.push((p.exceptionDetails?.exception?.description
                            ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 200));
                    }
                    break;
            }
        });

        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, pageSession).catch(() => { });
        // The same domains on both arms: an arm carrying a domain the other one
        // does not is a difference the guard can read (`two-arm-cdp-domain-symmetry`).
        for (const d of ['Runtime', 'Log', 'Page']) {
            await cdp.send(`${d}.enable`, undefined, pageSession).catch(() => { });
        }
        await cdp.send('Network.enable', { maxPostDataSize: 1048576 }, pageSession).catch(() => { });

        // Persona parity on about:blank, before the station sees anything: an arm
        // off the persona's scale or theme is not comparable, and both have been
        // mistaken for engine defects before.
        await pinPersonaMedia(cdp, pageSession);
        await assertPersonaParity(cdp, pageSession, { label: arm });

        await cdp.send('Page.navigate', { url: URL_ }, pageSession);
        await sleep(SETTLE);

        try {
            state.final = await cdp.send('Runtime.evaluate', {
                expression: `JSON.stringify({
                    href: location.href,
                    title: document.title,
                    clearance: /cf_clearance/.test(document.cookie),
                    text: (document.body ? document.body.innerText : '').slice(0, 200),
                })`,
                returnByValue: true,
            }, pageSession).then((r) => JSON.parse(r.result?.value ?? 'null'));
        } catch (err) { state.final = { err: String(err.message ?? err) }; }
    } catch (err) {
        state.error = String(err.message ?? err);
    } finally {
        cdp?.close();
        proc.kill('SIGKILL');
        if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
        await sleep(500);
    }

    // Same criterion as cf-token.mjs, so the two tools' columns can be compared.
    state.served = /bypassed/i.test(String(state.final?.text ?? ''));
    state.branch = branchOf(state.posts);
    state.seq = state.posts.map((e) => e.side).join(' -> ');
    // The fourth post is the last thing a passing arm does before the page
    // arrives, so its presence is worth its own column rather than being left
    // for the reader to count off the sequence.
    state.finalPagePost = state.posts.length >= 4 && state.posts[3].side === 'PAGE';
    state.engineLog = engineLog.join('').slice(-4000);
    return state;
}

const runs = [];
for (let pair = 0; pair < PAIRS; pair++) {
    for (const armSpec of ARMS) {
        const port = BASE_PORT + runs.length * 4;
        const st = await runOnce(armSpec, port);
        runs.push(st);
        const third = st.posts[2];
        console.log(`[${pair + 1}/${PAIRS}] ${armSpec.padEnd(20)}`
            + ` branch=${st.branch.padEnd(6)}`
            + ` 3rd ${third ? `${third.postLen} -> ${third.mime} ${third.encoded}` : '(absent)'}`.padEnd(42)
            + ` served=${st.served}  ${st.seq}`);
        if (st.error) console.log(`    error: ${st.error}`);
        if (OUT) {
            const p = path.resolve(OUT.replace(/\.json$/, '') + `-${armSpec.replace(/:/g, '-')}-${pair + 1}.json`);
            await fs.mkdir(path.dirname(p), { recursive: true });
            await fs.writeFile(p, JSON.stringify(st, null, 2));
        }
    }
}

console.log('');
const uniq = (xs) => [...new Set(xs)];
let jittered = false;
for (const armSpec of ARMS) {
    const mine = runs.filter((r) => r.arm === armSpec);
    const b = uniq(mine.map((r) => r.branch));
    if (b.length > 1) jittered = true;
    console.log(`${armSpec.padEnd(20)} branch ${b.join('/').padEnd(14)}`
        + ` finalPagePost ${mine.filter((r) => r.finalPagePost).length}/${mine.length}`
        + ` served ${mine.filter((r) => r.served).length}/${mine.length}`);
}

// `branch` tracks `served=` run for run, so a Chrome arm that drops its ticket
// moves this column too -- that is the tool working, not the tool breaking. Say
// so out loud, because the first reading of this table was three lucky Chrome
// runs mistaken for determinism.
const disagree = runs.filter((r) => (r.branch === 'clear') !== r.served);
if (disagree.length) {
    console.log(`\nWARNING: branch disagreed with served= on ${disagree.length}/${runs.length} runs`
        + ' -- the proxy does not hold in this window, trust served=');
    process.exit(1);
}
if (jittered) {
    console.log('\nnote: branch moved inside this window. Expected on an arm that drops a'
        + ' ticket (Chrome does so about 1 run in 6); only 0/N of `clear` refutes anything.');
}
