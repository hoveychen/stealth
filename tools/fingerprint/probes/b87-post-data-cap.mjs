// What `Network.enable`'s `maxPostDataSize` actually governs.
//
//   node tools/fingerprint/probes/b87-post-data-cap.mjs chrome
//   node tools/fingerprint/probes/b87-post-data-cap.mjs lightpanda
//
// Env: CHROME, LP_BIN, PORT (CDP port), HTTP (fixture port).
//
// This engine reads the parameter as "a body over this is dropped": the capture
// is discarded and `Network.getRequestPostData` then answers RequestNotFound.
// An existing cdp test asserts exactly that, so changing it needs a reading of
// what Chrome does rather than an appeal to the protocol docs.
//
// The reading that prompted this: on cf-scrapingcourse, `cf-verdict.mjs` gets
// 90167 bytes out of Chrome for the challenge's third POST -- inline `postData`
// absent (it is over the default 64KB), fetched afterwards through
// getRequestPostData -- and nothing at all out of this engine.
//
// Prints one line per arm: whether the body was inlined in requestWillBeSent,
// and what getRequestPostData answered.
import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../../..');
const { Cdp, sleep } = await import(path.join(HERE, '../cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: b87-post-data-cap.mjs <lightpanda|chrome>');
    process.exit(1);
}

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9484 : 9485);
const HTTP = Number(process.env.HTTP) || 8790;

// Comfortably over the documented 64KB default, and the same order as the cf
// round this is about. Override with BODY_LEN to find where Chrome's own
// ceiling actually is -- the documented default and the measured one disagree.
const BODY_LEN = Number(process.env.BODY_LEN) || 90 * 1024;

const PAGE = `<!DOCTYPE html><title>post cap</title><body><script>
window.__posted = fetch('/sink', { method: 'POST', body: 'x'.repeat(${BODY_LEN}) })
  .then((r) => r.text());
</script></body>`;

const server = http.createServer((req, res) => {
    if (req.url === '/page.html') {
        res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
        return void res.end(PAGE);
    }
    req.resume();
    req.on('end', () => {
        res.writeHead(200, { 'content-type': 'text/plain' });
        res.end('ok');
    });
});
await new Promise((r) => server.listen(HTTP, r));

const profile = engine === 'chrome' ? await fs.mkdtemp(path.join(os.tmpdir(), 'fp-pdcap-')) : null;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run', '--no-default-browser-check', '--headless=new',
        'about:blank',
    ], { stdio: 'ignore' })
    : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: 'ignore' });

await sleep(1200);
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

// No maxPostDataSize: the default is what the cf reading was taken under, and
// the question is what the DEFAULT cap governs.
await cdp.send('Network.enable', {}, sessionId);

let inlined = null;
let requestId = null;
// cdp.mjs's `on` takes the whole message, not a per-method handler.
cdp.on((m) => {
    if (m.method !== 'Network.requestWillBeSent') return;
    const p = m.params || {};
    if (!String(p.request?.url || '').endsWith('/sink')) return;
    requestId = p.requestId;
    inlined = (p.request.postData || '').length;
});

await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP}/page.html` }, sessionId);
await sleep(2500);

let fetched = '(never asked)';
if (requestId) {
    try {
        const r = await cdp.send('Network.getRequestPostData', { requestId }, sessionId);
        fetched = String((r?.postData || '').length);
    } catch (e) {
        fetched = '(error: ' + e.message + ')';
    }
}

console.log(`${engine}: bodyLen=${BODY_LEN} inlinedInRequestWillBeSent=${inlined} getRequestPostData=${fetched}`);

proc.kill();
server.close();
process.exit(0);
