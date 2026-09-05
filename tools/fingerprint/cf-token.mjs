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
//   node tools/fingerprint/cf-token.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--port n] [--out path]
// env: LP_BIN, CHROME
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: cf-token.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9272' : '9273'));
const OUT = arg('--out', null);
const headedUa = has('--headed-ua');

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

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE,
    userAgentOverride: null,
    tokens: [],      // one per distinct token, in arrival order
    bodyReads: [],   // every body fetch and its outcome
};

const seen = new Set();
const bodyUrl = new Map();   // requestId -> url, filled by responseReceived
const bodies = [];           // in-flight getResponseBody calls, awaited before the report

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

// A body that could not be read is not a body without a token in it, so every
// fetch's outcome is written down. That is what makes a run's silence mean
// something.
async function readBody(cdp, sessionId, requestId) {
    const url = bodyUrl.get(requestId) ?? '?';
    const rec = { url: url.slice(0, 140), ok: false, n: 0 };
    state.bodyReads.push(rec);
    try {
        const r = await cdp.send('Network.getResponseBody', { requestId }, sessionId);
        const text = String(r?.body ?? '');
        rec.ok = true;
        rec.n = text.length;
        // The transfer encoding and its decoding both: a token inside a base64
        // body is not findable in the base64 text. This engine marks every body
        // base64Encoded, Chrome only the binary ones, so both arms need both.
        scan(url, text);
        if (r?.base64Encoded) {
            try { scan(url, Buffer.from(text, 'base64').toString('latin1')); } catch { /* not base64 */ }
        }
    } catch (err) {
        rec.err = String(err?.message ?? err).slice(0, 120);
    }
}

if (headedUa) {
    if (engine !== 'chrome') { console.error('--headed-ua only makes sense with chrome'); process.exit(2); }
    state.userAgentOverride = await headedUserAgent(PORT + 1);
}

await runTrace({
    engine, url: URL_, settleMs: SETTLE, port: PORT, recorder: RECORDER, mark: MARK,
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

// Started while the run was up, collected here. A rejection is already recorded
// on its own bodyReads entry.
await Promise.allSettled(bodies);

// `served` is the criterion, not the ticket: cf-chl-out is handed out to arms
// that are then refused the page anyway.
state.served = /bypassed/i.test(String(state.final?.text ?? ''));
// The reading. Both stages' longest token, which is the one carrying the state
// blob -- the short ones in the same document are per-request nonces.
const longest = (stage) => state.tokens
    .filter((t) => t.stage === stage)
    .reduce((a, t) => (a && a.len >= t.len ? a : t), null);
state.reading = { edge: longest('edge'), widget: longest('widget') };

const okBodies = state.bodyReads.filter((b) => b.ok);
// A blob length of 4k+1 characters is not valid base64url; say so rather than
// printing a rounded block count that would read like a measurement.
const fmt = (t) => (!t ? '-'
    : t.bytes === null ? `${t.len} (blob ${t.blob} chars: not base64url)`
        : `${t.len} (${t.bytes} B = ${t.bytes / 16} blocks)`);
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
console.log(`bodies read: ${okBodies.length}/${state.bodyReads.length}  tokens: ${state.tokens.length}`);
console.log(`  edge   ${fmt(state.reading.edge)}`);
console.log(`  widget ${fmt(state.reading.widget)}`);
console.log(`served=${state.served}  ${JSON.stringify(state.final?.title ?? null)}`);
if (state.error) { console.log(`ERROR ${state.error}`); process.exitCode = 1; }

if (OUT) await writeRun(OUT, state);
