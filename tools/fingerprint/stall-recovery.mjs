// Does the CDP connection survive a watchdog stall?
//
// The real-station route cannot answer this on demand: a stall is probabilistic
// (one 29-station sweep hit it, the next two did not), so a green run proves
// nothing -- it may simply never have stalled. So cause one. A page whose script
// is `while(true){}` stalls deterministically at the watchdog timeout, and what
// matters is the navigation AFTER it:
//
//   before the fix: the stall's terminate reads as fatal in CDP.tick, which
//                   sends CLOSE_GOING_AWAY -- the next navigate hits a dead
//                   socket, which is exactly the sweep's "timeout: Page.navigate"
//   after the fix:  the terminate is marked recoverable, tick clears it and
//                   keeps serving, so the next navigate works
//
//   node tools/fingerprint/stall-recovery.mjs [--port 9951] [--http 9952] [--wait 36000]
// env: LP_BIN  (point it at the binary under test; run it once per arm)
//
// A pass is `stalled=true closed=false recovered=true`. `stalled=false` means
// the run proved nothing -- the watchdog never fired, so raise --wait rather
// than reading the other two columns. Measured either side of the fix
// (merge below): before, `closed=true recovered=false`; after,
// `closed=false recovered=true`, with the log line changing from
// `closing connection` to `page execution terminated`.
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, sleep, evaluate } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(n); return i === -1 ? d : process.argv[i + 1] };
const PORT = Number(arg('--port', 9951));
const HTTP_PORT = Number(arg('--http', 9952));
// The watchdog fires around 30s (the sweep logged stalled_ms=30466), so give it
// room to fire AND for the terminate to land before probing.
const WAIT = Number(arg('--wait', 36000));
const bin = process.env.LP_BIN ?? path.resolve(here, '../../zig-out/bin/lightpanda');

const PAGES = {
    '/spin.html': '<!DOCTYPE html><title>spin</title><script>while(true){}</script>',
    '/ok.html': '<!DOCTYPE html><title>ok</title><p id=marker>recovered</p>',
};
const server = http.createServer((req, res) => {
    const body = PAGES[req.url];
    if (!body) { res.writeHead(404); res.end('no'); return; }
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(body);
});
await new Promise((r) => server.listen(HTTP_PORT, '127.0.0.1', r));

const proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(PORT),
    '--log-level', 'warn'], { stdio: ['ignore', 'pipe', 'pipe'] });
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));
let exited = null;
proc.on('exit', (code, signal) => { exited = { code, signal } });

const out = { bin, stalled: null, closed: null, recovered: null, exited: null };
try {
    for (let i = 0; i < 80; i++) {
        try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break }
        catch { await sleep(250) }
    }
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);

    // Deliberately not awaited: the page never finishes parsing, so the reply
    // to this navigate may never come. The point is to occupy the thread.
    cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}/spin.html` }, sessionId)
        .catch(() => {});
    console.log(`spinning for ${WAIT}ms, waiting for the watchdog...`);
    await sleep(WAIT);

    const text = log.join('');
    out.stalled = /watchdog stall/.test(text);
    out.closed = /closing connection/.test(text);
    console.log(`  watchdog stall in log: ${out.stalled}`);
    console.log(`  "closing connection" in log: ${out.closed}`);

    // The question: can this same connection still drive a fresh navigation?
    try {
        await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}/ok.html` }, sessionId);
        await sleep(1500);
        const marker = await evaluate(cdp, sessionId, "document.getElementById('marker')?.textContent ?? 'missing'");
        out.recovered = String(marker) === 'recovered';
        console.log(`  navigation after the stall: ${out.recovered ? 'OK' : `read back ${JSON.stringify(marker)}`}`);
    } catch (e) {
        out.recovered = false;
        out.error = String(e.message ?? e).slice(0, 140);
        console.log(`  navigation after the stall FAILED: ${out.error}`);
    }
} catch (e) {
    out.error = String(e.message ?? e).slice(0, 200);
    console.log(`aborted: ${out.error}`);
} finally {
    out.exited = exited;
    console.log(`\nVERDICT stalled=${out.stalled} closed=${out.closed} recovered=${out.recovered} exited=${JSON.stringify(exited)}`);
    const keep = log.join('').split('\n').filter((l) => /watchdog|terminat|closing/i.test(l));
    for (const l of keep.slice(0, 8)) console.log(`  | ${l.slice(0, 180)}`);
    try { proc.kill('SIGTERM') } catch {}
    server.close();
    process.exit(0);
}
