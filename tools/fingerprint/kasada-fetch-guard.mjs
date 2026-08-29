// Pull down every script the Kasada challenge document loads, on either arm.
//
//   node kasada-fetch-guard.mjs <lightpanda|chrome> [--url U] [--port P] [--out DIR]
//
// The knob harness answers "does this change cost a ticket". This answers a
// question the page cannot: *what is the guard's own source*. Everything the
// station serves -- the 429 document, the bootstrap it inlines, the program it
// pulls -- is written to DIR, one file per response, plus a manifest.
//
// Runtime.enable is never sent: Kasada withholds clearance from a client that
// has one attached, and a body fetched with Network.getResponseBody after the
// verdict is already on the wire cannot have changed that verdict.
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const engine = process.argv[2];
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
const port = Number(arg('--port', 9400));
const target = arg('--url', 'https://www.hyatt.com/');
const settle = Number(arg('--settle', 16000));
const outDir = arg('--out', path.join(here, 'scratch', `guard-${engine}`));

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out-rel/bin/lightpanda');
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

const slug = (u) => {
    const p = new URL(u);
    const tail = (p.pathname.split('/').filter(Boolean).pop() || 'index').slice(-40);
    return `${p.hostname}_${tail}_${crypto.createHash('sha1').update(u).digest('hex').slice(0, 8)}`;
};

await fs.mkdir(outDir, { recursive: true });
const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'b85-guard-'));
const proc = engine === 'chrome'
    ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
        '--no-first-run', '--no-default-browser-check', `--user-agent=${UA}`],
    { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
        { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 200; i++) {
    try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
// requestId -> record. Bodies are pulled the moment loadingFinished fires, not
// after settle: the challenge document and the program it inlines live in the
// navigation that the ticket then replaces, and asking for them afterwards
// answers "No resource with given identifier found" -- which reads as a station
// that served nothing rather than a harness that asked too late.
const seen = new Map();
const manifest = [];
const pending = [];
try {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    // A cross-origin child frame is its own target in Chrome, so a page-session
    // listener never sees what it loads. Cloudflare's decision is made inside
    // the challenges.cloudflare.com widget, whose bundle is therefore invisible
    // to every instrument that only watches the page. --frames attaches to the
    // children as they appear and enables Network on each.
    //
    // Off by default: auto-attach is observable -- Kasada refuses a headed
    // Chrome that has it -- so a run that needs a verdict must not use it. A run
    // that only needs the bytes can, because the bundle is served before the
    // verdict is reached.
    const withFrames = process.argv.includes('--frames');
    const childSessions = new Set();
    if (withFrames) {
        cdp.on(async (m) => {
            if (m.method !== 'Target.attachedToTarget') return;
            const sid = m.params.sessionId;
            if (childSessions.has(sid)) return;
            childSessions.add(sid);
            try {
                await cdp.send('Network.enable', { maxPostDataSize: 1 << 20 }, sid);
                await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid).catch(() => {});
            } catch (e) { /* the target can die before we finish arming it */ }
        });
        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
    }

    const grab = async (requestId, rec) => {
        try {
            // A child target's document is sometimes only addressable from the
            // page session and sometimes only from its own, so try both rather
            // than recording "No resource with given identifier found" as a
            // station that served nothing.
            let res = null, lastErr = null;
            for (const sid of new Set([rec.session || sessionId, sessionId])) {
                try { res = await cdp.send('Network.getResponseBody', { requestId }, sid); break; }
                catch (e) { lastErr = e; }
            }
            if (!res) throw lastErr;
            const body = res.base64Encoded ? Buffer.from(res.body, 'base64').toString('utf8') : res.body;
            rec.bytes = Buffer.byteLength(body);
            rec.sha256 = crypto.createHash('sha256').update(body).digest('hex');
            rec.file = `${rec.type === 'Document' ? 'doc' : 'js'}_${slug(rec.url)}.txt`;
            await fs.writeFile(path.join(outDir, rec.file), body);
        } catch (e) {
            rec.error = String(e).slice(0, 120);
        }
        manifest.push({ requestId, ...rec });
    };

    cdp.on((m) => {
        if (m.method === 'Network.responseReceived') {
            const r = m.params.response;
            seen.set(m.params.requestId, {
                url: String(r.url || ''),
                type: m.params.type,
                status: r.status,
                mime: r.mimeType,
                session: m.sessionId || null,
            });
            return;
        }
        if (m.method !== 'Network.loadingFinished') return;
        const rec = seen.get(m.params.requestId);
        if (!rec || (rec.type !== 'Script' && rec.type !== 'Document')) return;
        pending.push(grab(m.params.requestId, rec));
    });
    await cdp.send('Page.enable', {}, sessionId);
    await cdp.send('Network.enable', { maxPostDataSize: 1 << 20 }, sessionId);
    await cdp.send('Page.navigate', { url: target }, sessionId);
    await sleep(settle);
    await Promise.all(pending);
} finally {
    cdp.close();
    proc.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}

await fs.writeFile(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`${engine} ${new URL(target).hostname}: ${seen.size} responses, ${manifest.length} script/document`);
for (const m of manifest) {
    console.log(`  ${String(m.status).padEnd(4)} ${String(m.type).padEnd(9)} ${String(m.bytes ?? '-').padStart(8)}B ` +
        `${(m.sha256 || '').slice(0, 12).padEnd(12)} ${m.url.slice(0, 110)}${m.error ? '  ERR ' + m.error : ''}`);
}
