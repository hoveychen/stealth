// Cloudflare's verdict on one visit, read off the challenge exchange instead of
// off whether the station served the page.
//
//   node tools/fingerprint/cf-verdict.mjs <lightpanda|chrome> [--runs 3] [--port 9450]
//
// The same argument kasada-verdict.mjs makes, for the other guard. A station's
// pass/refuse is the END of a chain, and the middle of it moves on its own --
// `antibot-stations-pass-in-windows` is a whole README section about stations
// opening and closing for every binary inside one hour. Worse here: BOTH arms
// answer `doc=403->200` on cf-scrapingcourse, so the document status does not
// even separate them. What separates them today is the page TITLE -- "Just a
// moment..." against the real one -- which is the last link in the chain and
// costs a `Runtime.evaluate` to read.
//
// The answer it found, and what it now keys on: **`cf-chl-out`** on the SECOND
// `fo/` telemetry POST's response. Chrome carries it 2 for 2 and this engine
// never does, and it arrives about four seconds before the clearance cookie and
// the re-navigation that follow from it. Unlike the cookie it is a plain
// response header, which matters: this engine reports no Set-Cookie to CDP at
// all -- neither on the response nor in ExtraInfo -- so `cf_clearance` cannot be
// read symmetrically and a cookie-based verdict would have read "refused" for
// instrumentation reasons on a run that passed.
//
// So this records the challenge exchange itself: every
// `/cdn-cgi/challenge-platform/` and `challenges.cloudflare.com` request and
// response, with the headers the guard's own decision travels in. What is
// deliberately NOT done is decide in advance which of them is the ticket --
// `x-kpsdk-r` was found by dumping the exchange and looking, not by guessing,
// and the same discipline applies here. Everything interesting is printed and
// the discriminator is whatever turns out to differ 3-for-3.
//
// Runtime.enable is never sent. Kasada withholds clearance from a client that
// has sent it (README, ks-canadagoose) and whether Cloudflare does is not
// something this tool should be the one to find out; the reading is taken
// entirely off Network events, exactly as the Kasada oracle is.
//
// Chrome runs HEADED and with a Chrome user agent by default, because that is
// the arm that passes: `HeadlessChrome` in the product token is measured fatal
// on this station, and a misconfigured arm once produced a retracted README
// section claiming no arm passed at all.
//
// Two instrument traps this tool has already fallen into and now handles, both
// worth reading before trusting a reading off it:
//
//   * Chrome isolates the Turnstile widget into its own target, so without
//     `Target.setAutoAttach` on every target the widget's whole exchange is
//     invisible on Chrome and visible on this engine -- which made the arms look
//     structurally different when they are not.
//   * `postData` is omitted for a large body. The round that matters is ~90KB,
//     and reading the field alone reported it as 0 bytes.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: cf-verdict.mjs <lightpanda|chrome> [--runs N] [--port P] [--url U] [--settle MS] [--headless] [--out PATH]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const runs = Number(arg('--runs', 3));
const basePort = Number(arg('--port', 9450));
const target = arg('--url', 'https://www.scrapingcourse.com/antibot-challenge');
const settle = Number(arg('--settle', 22000));
const outPath = arg('--out', null);
const headless = process.argv.includes('--headless');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

const isChallenge = (url) =>
    url.includes('/cdn-cgi/challenge-platform/') || url.includes('challenges.cloudflare.com');

// `cf-chl-out` is the ticket -- see the header block at the top of the file. The
// rest are kept because they say which stage of the challenge a reply belongs
// to, and because a new one showing up in the dump beats one being silently
// dropped.
const WATCH = [
    'cf-mitigated', 'cf-chl-gen', 'cf-chl-out', 'cf-ray', 'cf-cache-status',
    'content-type', 'content-length', 'set-cookie', 'server-timing',
];

function pick(headers) {
    const out = {};
    for (const [k, v] of Object.entries(headers || {})) {
        const key = k.toLowerCase();
        if (WATCH.includes(key)) out[key] = v;
    }
    return out;
}

async function once(port) {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'cf-verdict-'));
    const proc = engine === 'chrome'
        ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
            '--no-first-run', '--no-default-browser-check', `--user-agent=${UA}`,
            ...(headless ? ['--headless=new'] : [])],
        { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
            { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.resume();
    proc.stderr.resume();
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    const out = { documents: [], challenge: [], cookies: [], clearance: false };
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        const posted = new Map();
        cdp.on((m) => {
            // The POST bodies' sizes, so a round can be named by its shape the
            // way the Kasada rounds are.
            if (m.method === 'Network.requestWillBeSent') {
                const url = String(m.params.request?.url || '');
                if (!isChallenge(url)) return;
                // `postData` is omitted for a large body -- only `hasPostData`
                // is set -- and the challenge's third round is ~90KB, so
                // reading the field alone reported 0 bytes for the one POST
                // that matters most. Ask for it when it is missing.
                const req = m.params.request;
                const entry = {
                    method: req.method,
                    postLen: (req.postData || '').length,
                    postUnknown: !req.postData && !!req.hasPostData,
                };
                posted.set(m.params.requestId, entry);
                if (entry.postUnknown) {
                    cdp.send('Network.getRequestPostData', { requestId: m.params.requestId },
                        m.sessionId)
                        .then((r) => {
                            entry.postLen = (r?.postData || '').length;
                            entry.postUnknown = false;
                        })
                        .catch(() => { /* body already gone; stays unknown */ });
                }
                return;
            }
            // Chrome puts Set-Cookie in ExtraInfo rather than in the response
            // headers -- cdp-fields-arent-symmetric -- so both are watched and
            // the cookie question is answered off whichever arrives.
            if (m.method === 'Network.responseReceivedExtraInfo') {
                const raw = m.params.headers || {};
                for (const [k, v] of Object.entries(raw)) {
                    if (k.toLowerCase() !== 'set-cookie') continue;
                    for (const line of String(v).split('\n')) {
                        const name = line.split('=')[0].trim();
                        if (name) out.cookies.push(name);
                        if (name === 'cf_clearance') out.clearance = true;
                    }
                }
                return;
            }
            if (m.method !== 'Network.responseReceived') return;
            const r = m.params.response;
            const url = String(r.url);
            if (m.params.type === 'Document') out.documents.push({ url, status: r.status });
            if (!isChallenge(url)) return;
            const headers = pick(r.headers);
            const sent = posted.get(m.params.requestId) || {};
            if (headers['set-cookie']) {
                for (const line of String(headers['set-cookie']).split('\n')) {
                    const name = line.split('=')[0].trim();
                    if (name) out.cookies.push(name);
                    if (name === 'cf_clearance') out.clearance = true;
                }
            }
            out.challenge.push({
                // The path only: the host is always one of the two matched above
                // and the query carries a per-visit token that would make two
                // runs look different for no reason.
                path: url.replace(/^https?:\/\/[^/]+/, '').split('?')[0],
                method: sent.method || 'GET',
                postLen: sent.postLen || 0,
                postUnknown: !!sent.postUnknown,
                status: r.status,
                ...headers,
            });
        });
        // Auto-attach, or Chrome's Turnstile iframe is invisible. The widget
        // runs cross-origin on challenges.cloudflare.com, which Chrome puts in
        // its OWN target -- so a listener on the page's session alone sees the
        // page-level challenge and nothing the widget does. This engine does not
        // isolate that frame, so its widget traffic arrives on the page session,
        // and the two arms then look structurally different for a reason that is
        // entirely the instrument: the first version of this tool reported
        // "Chrome: 1 challenge instance, this engine: 2" and both arms in fact
        // use two. cdp-fields-arent-symmetric, in the one place that would have
        // sent a session chasing a control-flow bug that does not exist.
        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
        cdp.on(async (m) => {
            if (m.method !== 'Target.attachedToTarget') return;
            const child = m.params.sessionId;
            try { await cdp.send('Network.enable', {}, child); } catch { /* gone already */ }
            try {
                await cdp.send('Target.setAutoAttach',
                    { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, child);
            } catch { /* not a target that nests */ }
        });
        await cdp.send('Page.enable', {}, sessionId);
        await cdp.send('Network.enable', {}, sessionId);
        await cdp.send('Page.navigate', { url: target }, sessionId);
        await sleep(settle);
    } finally {
        cdp.close();
        proc.kill('SIGKILL');
        await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
    }
    return out;
}

const all = [];
for (let i = 0; i < runs; i++) {
    const out = await once(basePort + i);
    all.push(out);
    const docs = out.documents.map((d) => d.status).join('->') || '(none)';
    const fo = out.challenge.filter((c) => c.path.includes('/fo/'));
    // The instance a `fo/` POST is addressed to, which is the first field of the
    // path segment after `/fo/`. Chrome posts every round back to the one the
    // page-level challenge opened; a second id appearing here is the divergence
    // this tool was built to see.
    const instance = (c) => (c.path.split('/fo/')[1] || '').split(':')[0];
    const ticket = fo.find((c) => c['cf-chl-out']);
    const rounds = fo
        .map((c, n) => `r${n + 1}:${c.postUnknown ? '?' : c.postLen}B@${instance(c)}` +
            (c['cf-chl-out'] ? '=TICKET' : c['cf-chl-gen'] ? '=chl-gen' : ''))
        .join(' ');
    const pat = out.challenge.filter((c) => c.path.includes('/pat/'));
    console.log(`${engine}${headless ? ' (headless)' : ''} run ${i + 1}: doc=${docs} ` +
        `ticket=${ticket ? String(ticket['cf-chl-out']).slice(0, 12) : '(absent)'} ` +
        `rounds=[${rounds}] instances=${new Set(fo.map(instance)).size}` +
        (pat.length ? ` pat=${pat.map((c) => c.status).join(',')}` : '') +
        // Chrome-only: this engine reports no Set-Cookie to CDP at all, on
        // either the response headers or ExtraInfo, so a false here is an
        // instrumentation gap and NOT a verdict. cf-chl-out is the verdict.
        (out.cookies.length ? ` cookies=[${[...new Set(out.cookies)].join(',')}]` : ''));
}

if (outPath) {
    await fs.writeFile(outPath, JSON.stringify({ engine, headless, target, runs: all }, null, 2));
    console.log(`wrote ${outPath}`);
}
