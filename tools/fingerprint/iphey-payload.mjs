// What iphey SENDS. Its verdict text ("Detected an inconsistent browser
// fingerprint") appears in none of the four scripts the page loads, so the
// grade is computed server-side from a collected payload -- which makes the
// payload, not the page, the thing to diff between the two arms.
//
//   node tools/fingerprint/iphey-payload.mjs <lightpanda|chrome> [--out results/x.json]
//        [--port 9280] [--settle 15000] [--headed] [--url https://iphey.com/]
//
// Every request body leaving the page is captured, keyed by URL, so a diff can
// be taken field by field rather than guessed at from the rendered report.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: iphey-payload.mjs <lightpanda|chrome> [--out results/x.json] [--port N] [--settle MS] [--headed]');
    process.exit(2);
}
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i === -1 ? fallback : process.argv[i + 1];
};
const PORT = Number(arg('--port', engine === 'chrome' ? 9381 : 9280));
const SETTLE = Number(arg('--settle', 15000));
const URL_ = arg('--url', 'https://iphey.com/');
const headed = process.argv.includes('--headed');
const outPath = path.resolve(repo, arg('--out', `results/iphey-payload-${engine}.json`));
const CHROME = process.env.CHROME_BIN
    || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

let proc, profile;
if (engine === 'chrome') {
    profile = await fs.mkdtemp(path.join(os.tmpdir(), 'ip-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check',
        ...personaScaleFlags(),
        '--window-size=1920,1080',
        ...(headed ? [] : ['--headless=new']),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'), [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 300; i++) {
    try {
        await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
        break;
    } catch {
        await sleep(200);
    }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { sessionId } = await newPage(cdp);
const requests = [];
// The report is collected over `wss://api.iphey.com`, not posted: no request
// body carries it, so the frames are the payload.
const frames = [];
cdp.on((msg) => {
    if (msg.method === 'Network.webSocketFrameSent' || msg.method === 'Network.webSocketFrameReceived') {
        frames.push({ dir: msg.method.endsWith('Sent') ? 'out' : 'in', payload: msg.params.response?.payloadData ?? '' });
        return;
    }
    if (msg.method !== 'Network.requestWillBeSent') return;
    const r = msg.params.request;
    if (r.method === 'GET' && !/iphey|api|check|fp|collect/i.test(r.url)) return;
    requests.push({ url: r.url, method: r.method, headers: r.headers, body: r.postData ?? null, requestId: msg.params.requestId });
});
await cdp.send('Network.enable', {}, sessionId);
// Page.enable first: without it addScriptToEvaluateOnNewDocument is a silent
// no-op on this engine.
await cdp.send('Page.enable', {}, sessionId);
// This engine reports no Network.webSocketFrame* events, so the frames above
// come back empty on the lightpanda arm even when the socket carried the whole
// report. Hooking send() reads the same bytes symmetrically on both arms.
// --knock <face> blanks one collection face in BOTH arms, so the drop in the
// payload's length says how many bytes that face is worth. The payload is
// encrypted, which rules out reading it; its length is not, and it is steady to
// ~50 bytes across runs, so a face worth thousands shows up plainly.
const KNOCKS = {
    canvas: `HTMLCanvasElement.prototype.toDataURL = () => '';
             CanvasRenderingContext2D.prototype.getImageData = function () { return new ImageData(1, 1); };`,
    webgl: `HTMLCanvasElement.prototype.getContext = ((orig) => function (type, ...rest) {
                return /webgl|webgpu/i.test(String(type)) ? null : orig.call(this, type, ...rest);
            })(HTMLCanvasElement.prototype.getContext);`,
    audio: `globalThis.AudioContext = undefined; globalThis.OfflineAudioContext = undefined;
            globalThis.webkitAudioContext = undefined; globalThis.webkitOfflineAudioContext = undefined;`,
    fonts: `Object.defineProperty(document, 'fonts', { get: () => undefined, configurable: true });`,
    rects: `Element.prototype.getClientRects = function () { return []; };
            Element.prototype.getBoundingClientRect = function () { return new DOMRect(0, 0, 0, 0); };`,
    media: `globalThis.MediaSource = undefined;
            HTMLMediaElement.prototype.canPlayType = () => '';
            Navigator.prototype.requestMediaKeySystemAccess = undefined;`,
    perf: `Performance.prototype.getEntries = () => [];
           Performance.prototype.getEntriesByType = () => [];`,
};
const knock = arg('--knock', null);
if (knock && !KNOCKS[knock]) {
    console.error(`unknown --knock ${knock}; have: ${Object.keys(KNOCKS).join(', ')}`);
    process.exit(2);
}
await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `(() => {
        ${knock ? KNOCKS[knock] : ''}
        // Which audio graph the page builds. chrome_audio.zig only has a
        // recorded render for two of them and hands silence to anything else,
        // so the graph's settings decide whether our arm has an answer at all.
        globalThis.__audio = [];
        if (globalThis.OfflineAudioContext) {
            const OAC = globalThis.OfflineAudioContext;
            globalThis.OfflineAudioContext = function (...a) {
                const ctx = new OAC(...a);
                const note = { ctor: a.map((x) => (typeof x === 'object' ? JSON.stringify(x) : x)) };
                globalThis.__audio.push(note);
                const osc = ctx.createOscillator.bind(ctx);
                ctx.createOscillator = () => {
                    const o = osc();
                    queueMicrotask(() => { note.osc = { type: o.type, frequency: o.frequency.value, detune: o.detune.value }; });
                    setTimeout(() => { note.oscLate = { type: o.type, frequency: o.frequency.value }; }, 0);
                    return o;
                };
                const cmp = ctx.createDynamicsCompressor.bind(ctx);
                ctx.createDynamicsCompressor = () => {
                    const c = cmp();
                    setTimeout(() => {
                        note.comp = {
                            threshold: c.threshold.value, knee: c.knee.value, ratio: c.ratio.value,
                            attack: c.attack.value, release: c.release.value,
                        };
                    }, 0);
                    return c;
                };
                // The graph's *shape*, not just its numbers: canonical_render
                // matches on the destination's incoming edges, so an extra node
                // in the chain is the difference between a replay and silence.
                note.edges = [];
                const tag = (n) => (n === ctx.destination ? 'destination' : (n?.constructor?.name ?? String(n)));
                for (const proto of [AudioNode.prototype]) {
                    const c = proto.connect;
                    proto.connect = function (dst, ...rest) {
                        try { note.edges.push(tag(this) + '->' + tag(dst) + (rest.length ? '#' + rest.join(',') : '')); } catch {}
                        return c.call(this, dst, ...rest);
                    };
                }
                const render = ctx.startRendering.bind(ctx);
                ctx.startRendering = () => render().then((buf) => {
                    const ch = buf.getChannelData(0);
                    let sum = 0;
                    for (let i = Math.max(0, ch.length - 500); i < ch.length; i++) sum += Math.abs(ch[i]);
                    note.tailSum = sum;
                    note.frames = buf.length;
                    return buf;
                });
                return ctx;
            };
            globalThis.OfflineAudioContext.prototype = OAC.prototype;
        }
        globalThis.__wsSent = [];
        const send = WebSocket.prototype.send;
        WebSocket.prototype.send = function (data) {
            try { globalThis.__wsSent.push(typeof data === 'string' ? data : '[binary ' + (data.byteLength ?? data.size) + ']'); } catch {}
            return send.call(this, data);
        };
    })()`,
}, sessionId);
await cdp.send('Page.navigate', { url: URL_ }, sessionId);
await sleep(SETTLE);

const audio = await cdp.send('Runtime.evaluate', {
    expression: 'JSON.stringify(globalThis.__audio ?? [])',
    returnByValue: true,
}, sessionId).then((r) => JSON.parse(r.result?.value ?? '[]')).catch(() => []);
console.log(`  audio graphs: ${JSON.stringify(audio)}`);

const hooked = await cdp.send('Runtime.evaluate', {
    expression: 'JSON.stringify(globalThis.__wsSent ?? [])',
    returnByValue: true,
}, sessionId).then((r) => JSON.parse(r.result?.value ?? '[]')).catch((e) => [`ERR ${e.message}`]);
for (const p of hooked) frames.push({ dir: 'out-hook', payload: p });

// postData is absent on a body the engine streamed rather than buffered; ask
// for it explicitly before the page is torn down.
for (const r of requests) {
    if (r.body) continue;
    try {
        const { postData } = await cdp.send('Network.getRequestPostData', { requestId: r.requestId }, sessionId);
        r.body = postData ?? null;
    } catch (e) {
        r.bodyError = String(e.message ?? e);
    }
}

await fs.mkdir(path.dirname(outPath), { recursive: true });
await fs.writeFile(outPath, JSON.stringify({ engine, url: URL_, settle: SETTLE, knock, requests, frames }, null, 1));
console.log(`${engine}: ${requests.length} requests, ${frames.length} ws frames -> ${path.relative(repo, outPath)}`);
for (const f of frames) console.log(`  ws ${f.dir} ${f.payload.length}`);
for (const r of requests) console.log(`  ${r.method} ${r.url.slice(0, 90)} body=${r.body ? r.body.length : (r.bodyError ? 'ERR' : 0)}`);

cdp.close();
proc.kill('SIGKILL');
if (profile) await fs.rm(profile, { recursive: true, force: true });
