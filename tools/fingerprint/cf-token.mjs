// Cloudflare's own opinion of this session, read off the wire in one run.
//
// The challenge hands the client two `<43>-<unix ts>-1.x.1.1-<blob>` tokens, and
// the blob is a ciphertext of state the server keeps about the session. Its
// length is therefore a *readout*: every observed value is a whole number of
// 16-byte blocks, and the count is what the server chose to record.
//
// Two properties make it worth a tool of its own:
//
//   * it is deterministic. Ten runs in one window, five per arm, gave one value
//     per arm with no jitter at all -- where `served=` is a 1-in-6 lottery that
//     needs many runs before a reading means anything.
//   * it lands before the verdict. The long token arrives inside the widget
//     program, which is what then runs rounds 1 to 3, so the reading is
//     available about three minutes in and does not depend on how the challenge
//     ends.
//
// What it measured on 2026-09-04, same window, station-level alternation:
//
//   chrome (UA says HeadlessChrome)   edge 1301   widget 1535 (69 blocks)  0/5 served
//   chrome --headed-ua                edge 1279   widget 1514 (68 blocks)  2/2 served
//   lightpanda                        edge 1279   widget 1663 (75 blocks)  0/5 served
//
// So the edge stage records the same thing about this engine as it does about
// the arm that clears, and the whole difference -- 7 blocks, 112 bytes -- is
// recorded in the widget stage.
//
// Readings are only comparable inside one window: the same headless Chrome read
// 1279/1514 on 2026-08-xx (the b111 captures) and 1301/1535 the next day. Always
// run a reference arm alongside.
//
// usage:
//   node tools/fingerprint/cf-token.mjs <lightpanda|chrome> [--headed-ua]
//   node tools/fingerprint/cf-token.mjs --arms lightpanda,chrome:headed-ua --pairs 3
//        [--ref <arm>] [--url u] [--settle ms] [--port n] [--out path]
// env: LP_BIN, CHROME
//
// `--out p.json` writes one run file per arm per pair, named `p-<arm>-<i>.json`.
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const BASE_PORT = Number(arg('--port', '9272'));
const OUT = arg('--out', null);

// One arm is `<engine>` or `<engine>:headed-ua`. `--arms` takes a comma list and
// turns this into an alternation; a bare engine argument is the single-arm form.
//
// The alternation is station-level -- one run of each arm, then the next pair --
// and not block-level. On a station that hardens with each visit, running all of
// arm A and then all of arm B gives the arm that went first a page the other one
// never sees.
const ARM_SPECS = (arg('--arms', null) ?? process.argv[2] ?? '').split(',').filter(Boolean);
const ARMS = ARM_SPECS.map((spec, i) => {
    const [engine, ...opts] = spec.split(':');
    // The bare `--headed-ua` flag is the single-arm spelling. With several arms
    // it would be ambiguous which one it meant, so there it has to be written
    // into the arm as `chrome:headed-ua`.
    const headedUa = opts.includes('headed-ua') || (ARM_SPECS.length === 1 && has('--headed-ua'));
    return { spec: headedUa && !opts.length ? `${spec}:headed-ua` : spec, engine, headedUa, port: BASE_PORT + i * 4 };
});
const PAIRS = Number(arg('--pairs', '1'));
// Readings are only comparable inside one window, so the arm everything else is
// measured against has to be one of the arms in this same alternation.
const REF = arg('--ref', null);

if (!ARMS.length || ARMS.some((a) => a.engine !== 'lightpanda' && a.engine !== 'chrome')) {
    console.error('usage: cf-token.mjs <lightpanda|chrome>[:headed-ua] [--headed-ua] [--out p]');
    console.error('       cf-token.mjs --arms lightpanda,chrome:headed-ua --pairs 3 [--ref chrome:headed-ua]');
    process.exit(2);
}

// 43 characters, a unix second count, a four-part version, then the blob.
//
// Found by scanning for the fixed version substring and walking the token's
// character class outwards, not with a regular expression: `[A-Za-z0-9._-]{20,}`
// in front of a fixed tail backtracks once per start position, which on an 87 KB
// round-3 body is quadratic and hangs the run rather than reporting anything.
const VERSIONS = ['-1.2.1.1-', '-1.3.1.1-', '-1.1.1.1-', '-1.0.1.1-'];
const TOKEN_CHARS = new Set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-');

function* findTokens(text) {
    for (const ver of VERSIONS) {
        let i = text.indexOf(ver);
        while (i >= 0) {
            let a = i;
            while (a > 0 && TOKEN_CHARS.has(text[a - 1])) a--;
            let b = i + ver.length;
            while (b < text.length && TOKEN_CHARS.has(text[b])) b++;
            yield { token: text.slice(a, b), ver: ver.slice(1, -1), blobAt: i + ver.length - a };
            i = text.indexOf(ver, i + 1);
        }
    }
}

/// base64url without padding: 4 characters carry 3 bytes, a remainder of 2
/// carries 1 and a remainder of 3 carries 2. A remainder of 1 cannot occur and
/// is reported as such rather than rounded away.
function blobBytes(n) {
    const r = n % 4;
    if (r === 1) return null;
    return (n - r) / 4 * 3 + (r === 0 ? 0 : r - 1);
}

/// Which of the challenge's two stages handed this token over. The edge issues
/// one with the page HTML, before any script has run; the challenge platform
/// issues the other inside the widget program, after round 1.
function stageOf(url) {
    if (/\/new\/normal/.test(url)) return 'widget';
    if (/challenges\.cloudflare\.com|challenge-platform/.test(url)) return 'platform';
    return 'edge';
}

// Inert: this tool asks the wire. A page-side hook is what the eight negative
// provenance channels already were. The one line keeps the realm bookkeeping
// honest about which realms were reachable at all.
const MARK = '@@CFTOK@@';
const RECORDER = `(function(){try{console.log(${JSON.stringify(MARK)}+JSON.stringify({k:'installed',
  href:String((globalThis.location||{}).href||'?').slice(0,200),
  worker:typeof globalThis.WorkerGlobalScope!=='undefined'}));}catch(e){}})();`;

/// One run of one arm. Everything the reading depends on is rebuilt per run --
/// the token set, the body bookkeeping -- so a second run of the same arm cannot
/// inherit the first one's tokens and read as jitter-free when it is not.
async function readOnce({ engine, headedUa, port }) {
    const state = {
        engine, url: URL_, headedUa, settleMs: SETTLE,
        userAgentOverride: null,
        tokens: [],      // one per distinct token, in arrival order
        bodyReads: [],   // every body fetch and its outcome
    };
    const seen = new Set();
    const bodyUrl = new Map();   // requestId -> url, filled by responseReceived
    const bodies = [];           // in-flight getResponseBody calls, awaited below

    function scan(url, text) {
        if (typeof text !== 'string' || !text) return;
        for (const { token, ver, blobAt } of findTokens(text)) {
            if (seen.has(token)) continue;
            seen.add(token);
            const blob = token.length - blobAt;
            state.tokens.push({
                ver, stage: stageOf(url), len: token.length, blob, bytes: blobBytes(blob),
                url: String(url).slice(0, 140), head: token.slice(0, 20),
            });
        }
    }

    // A body that could not be read is not a body without a token in it, so
    // every fetch's outcome is written down. That is what makes a run's silence
    // on this channel mean something.
    async function readBody(cdp, sessionId, requestId) {
        const url = bodyUrl.get(requestId) ?? '?';
        const rec = { url: url.slice(0, 140), ok: false, n: 0 };
        state.bodyReads.push(rec);
        try {
            const r = await cdp.send('Network.getResponseBody', { requestId }, sessionId);
            const text = String(r?.body ?? '');
            rec.ok = true;
            rec.n = text.length;
            // The transfer encoding and its decoding both: a token inside a
            // base64 body is not findable in the base64 text. This engine marks
            // every body base64Encoded and Chrome only the binary ones, so both
            // arms need both.
            scan(url, text);
            if (r?.base64Encoded) {
                try { scan(url, Buffer.from(text, 'base64').toString('latin1')); } catch { /* not base64 */ }
            }
        } catch (err) {
            rec.err = String(err?.message ?? err).slice(0, 120);
        }
    }

    if (headedUa) {
        if (engine !== 'chrome') throw new Error('headed-ua only makes sense on chrome');
        state.userAgentOverride = await headedUserAgent(port + 1);
    }

    await runTrace({
        engine, url: URL_, settleMs: SETTLE, port, recorder: RECORDER, mark: MARK,
        userAgentOverride: state.userAgentOverride, logLevel: arg('--log-level', 'info'), state,
        onMessage(msg, st, cdp) {
            const p = msg.params ?? {};
            if (msg.method === 'Network.responseReceived') {
                bodyUrl.set(p.requestId, String(p.response?.url ?? ''));
            } else if (msg.method === 'Network.loadingFinished') {
                bodies.push(readBody(cdp, msg.sessionId, p.requestId));
            }
        },
    });
    // Started while the run was up, collected here. A rejection is already
    // recorded on its own bodyReads entry.
    await Promise.allSettled(bodies);

    // `served` is the criterion, not the ticket: cf-chl-out is handed out to
    // arms that are then refused the page anyway.
    state.served = /bypassed/i.test(String(state.final?.text ?? ''));
    // The reading: each stage's longest token, which is the one carrying the
    // state blob. The short ones in the same document are per-request nonces.
    const longest = (stage) => state.tokens
        .filter((t) => t.stage === stage)
        .reduce((a, t) => (a && a.len >= t.len ? a : t), null);
    state.reading = { edge: longest('edge'), widget: longest('widget') };
    return state;
}

// A blob length of 4k+1 characters is not valid base64url; say so rather than
// print a rounded block count that would read like a measurement.
const fmt = (t) => (!t ? '-'
    : t.bytes === null ? `${t.len} (blob ${t.blob} chars: not base64url)`
        : `${t.len} (${t.bytes} B = ${t.bytes / 16} blocks)`);
const blocks = (t) => (t && t.bytes !== null ? t.bytes / 16 : null);

const runs = [];
for (let i = 1; i <= PAIRS; i++) {
    for (const armIdx of ARMS.keys()) {
        const arm = ARMS[armIdx];
        const st = await readOnce(arm);
        runs.push({ pair: i, arm: arm.spec, state: st });
        const ok = st.bodyReads.filter((b) => b.ok).length;
        console.log(`[${i}/${PAIRS}] ${arm.spec.padEnd(20)}`
            + ` edge ${fmt(st.reading.edge).padEnd(28)} widget ${fmt(st.reading.widget).padEnd(28)}`
            + ` served=${st.served}  bodies ${ok}/${st.bodyReads.length}`
            + (st.error ? `  ERROR ${st.error}` : ''));
        if (OUT) await writeRun(OUT.replace(/\.json$/, `-${arm.spec.replace(/:/g, '-')}-${i}.json`), st);
    }
}

// --- summary ---------------------------------------------------------------
// Per arm: the set of values it gave, because one value over N runs is the
// property that makes this a reading rather than a sample, and two values is
// worth seeing rather than averaging away.
console.log('');
const perArm = new Map();
for (const r of runs) {
    const a = perArm.get(r.arm) ?? { edge: [], widget: [], served: 0, n: 0 };
    a.edge.push(blocks(r.state.reading.edge));
    a.widget.push(blocks(r.state.reading.widget));
    a.served += r.state.served ? 1 : 0;
    a.n++;
    perArm.set(r.arm, a);
}
const uniq = (xs) => [...new Set(xs)].sort((x, y) => (x ?? -1) - (y ?? -1));
const refArm = REF ?? [...perArm.keys()].find((k) => perArm.get(k).served > 0) ?? null;
const refWidget = refArm ? uniq(perArm.get(refArm).widget) : [];
for (const [spec, a] of perArm) {
    const w = uniq(a.widget);
    // The gap only means anything against an arm measured in this same window,
    // so it is only printed when the reference is one of the arms that ran.
    const gap = (refWidget.length === 1 && w.length === 1 && w[0] !== null && refWidget[0] !== null)
        ? `  ${w[0] - refWidget[0] >= 0 ? '+' : ''}${w[0] - refWidget[0]} blocks vs ${refArm}` : '';
    console.log(`${spec.padEnd(20)} edge blocks ${uniq(a.edge).join('/').padEnd(10)}`
        + ` widget blocks ${w.join('/').padEnd(10)} served ${a.served}/${a.n}${gap}`);
}
if (!refArm) console.log('(no arm was served in this window: no reference to measure the gap against)');
if (runs.some((r) => r.state.error)) process.exitCode = 1;
