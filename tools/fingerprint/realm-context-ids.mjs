// Which executionContextId does a host see for each realm on a page?
//
// A CDP client tells realms apart by `executionContextId`: every
// `Runtime.consoleAPICalled` carries the id of the context that called console,
// and `Runtime.executionContextCreated` announces each one with a name and an
// auxData naming its frame. That is how a host attributes a log line to a frame
// without trusting the page to tag itself. The fingerprint instruments in this
// directory tag realms page-side precisely because this engine did not.
//
// The page is one document with two same-origin iframes, so all three realms
// live in one target and one session -- no OOPIF, nothing that needs
// auto-attach. Each realm logs its own name.
//
// usage: node realm-context-ids.mjs <chrome|lightpanda> [--port 9171]
// env: CHROME, LP_BIN
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const engine = process.argv[2];
const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
const PORT = Number(arg('--port', '9171'));
const WEB = PORT + 1;
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || '/Users/hoveychen/workspace/stealth/zig-out/bin/lightpanda';

const say = (who) => `<script>console.log('@@${who}@@');</script>`;
const pages = {
    '/top.html': `<!DOCTYPE html><html><body>
<iframe src="/kid-a.html"></iframe>
<iframe src="/kid-b.html"></iframe>
${say('top')}
</body></html>`,
    '/kid-a.html': `<!DOCTYPE html><html><body>a${say('kid-a')}</body></html>`,
    '/kid-b.html': `<!DOCTYPE html><html><body>b${say('kid-b')}</body></html>`,
};

const server = await new Promise((r) => {
    const s = http.createServer((req, res) => {
        const body = pages[req.url.split('?')[0]];
        res.writeHead(body ? 200 : 404, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        res.end(body ?? 'no');
    });
    s.listen(WEB, '127.0.0.1', () => r(s));
});

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'rcid-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new'], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', () => { });
proc.stderr.on('data', () => { });

const logs = [];
const created = [];
let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) break;
        } catch { /* not up yet */ }
        await sleep(250);
    }
    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    cdp.on((msg) => {
        const p = msg.params ?? {};
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
            const m = /@@([a-z-]+)@@/.exec(text);
            if (m) logs.push({ who: m[1], ctx: p.executionContextId });
        }
        if (msg.method === 'Runtime.executionContextCreated') {
            const c = p.context ?? {};
            created.push({ id: c.id, name: c.name, origin: c.origin, aux: c.auxData });
        }
    });
    for (const d of ['Runtime', 'Page']) await cdp.send(`${d}.enable`, undefined, sessionId).catch(() => { });
    await cdp.send('Page.navigate', { url: `http://127.0.0.1:${WEB}/top.html` }, sessionId);
    await sleep(4000);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    server.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

const ids = new Set(logs.map((l) => l.ctx));
console.log(JSON.stringify({
    engine,
    logs,
    distinctContextIds: ids.size,
    executionContextCreated: created,
}, null, 1));
