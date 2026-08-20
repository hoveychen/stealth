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
    console.error('usage: antibot-sweep.mjs <lightpanda|chrome> [--out results/x.json] [--proxy socks5h://host:port] [--headed] [--window-size 1920,1080] [--only cf-]');
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
            ...(headed ? [] : ['--headless=new']),
            ...(proxy ? [`--proxy-server=${proxy}`] : []),
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
        proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
            'serve', '--host', '127.0.0.1', '--port', String(PORT),
            ...(proxy ? ['--http-proxy', proxy] : []),
        ], { stdio: ['ignore', 'pipe', 'pipe'] });
    }
    proc.stdout.on('data', keep);
    proc.stderr.on('data', keep);
}

async function teardown() {
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
const onEvent = (msg) => {
    const p = msg.params ?? {};
    if (trace) {
        if (msg.method === 'Network.requestWillBeSent') {
            wire.push({ ev: 'req', method: p.request?.method, url: p.request?.url, type: p.type });
        } else if (msg.method === 'Network.responseReceived') {
            wire.push({ ev: 'res', status: p.response?.status, url: p.response?.url, type: p.type });
        } else if (msg.method === 'Network.loadingFailed') {
            wire.push({ ev: 'fail', text: p.errorText, url: p.request?.url });
        } else if (msg.method === 'Runtime.consoleAPICalled') {
            wire.push({
                ev: `console.${p.type}`,
                text: (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ').slice(0, 300),
            });
        } else if (msg.method === 'Runtime.exceptionThrown') {
            wire.push({ ev: 'exception', text: (p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '').slice(0, 300) });
        }
    }
    if (msg.method !== 'Network.responseReceived') return;
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
    const jsDetect = !!(cf.chlOpt || cf.platformScript);
    const out = { ...base, jsDetect };
    if (cf.blocked) return { verdict: 'cf-blocked', ...out };
    if (cf.justAMoment || cf.challengeDom) return { verdict: 'cf-challenge', ...out };
    if (dd.captchaDelivery || dd.blockText) return { verdict: 'datadome-challenge', ...out };
    // No interstitial. A 4xx/5xx document with nothing rendered over it is still
    // a refusal -- some guards answer a bare 403 with no page at all -- and an
    // empty document behind a 200 is the engine failing to render, not a pass.
    if (last !== null && last >= 400) return { verdict: `refused-${last}`, ...out };
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
        await cdp.send('Network.enable', {}, sessionId);
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
        row.documents = docs.slice(0, 12);
        if (trace) row.wire = wire.slice(0, 400);
        Object.assign(row, verdict(station, reading, docs));
        if (reading) {
            row.title = reading.title;
            row.landedOn = reading.href;
            row.nodes = reading.nodes;
            row.textLength = reading.textLength;
            row.snippet = reading.text.replace(/\s+/g, ' ').slice(0, 200);
            row.marks = { ...reading.cf, ...reading.dd };
        }
        row.ms = Date.now() - started;
        snapshot.stations.push(row);
        console.log(
            `${String(row.ms).padStart(6)}ms ${station.name.padEnd(18)} ${String(row.verdict).padEnd(19)} ` +
            `doc=${row.first ?? '-'}${row.last !== row.first ? `->${row.last}` : ''} ` +
            `nodes=${String(row.nodes ?? '-').padStart(5)} ${row.error ? `ERR ${row.error}` : `"${(row.title ?? '').slice(0, 40)}"`}`,
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
