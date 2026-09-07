// Is nested flex layout exponential? An offline, deterministic reading -- no
// antibot station, no window to wait for.
//
//   node tools/fingerprint/flex-cost.mjs [--bin PATH] [--port 9253] [--k 3]
//                                  [--depths 1,2,3,4,5,6,7,8]
//
// The wedge on ak-kohls samples 27 nested `Element.dimensionsIn` frames
// alternating with `CSSStyleDeclaration.flexItemWidth`, and flexItemWidth's
// growing-item branch measures EVERY sibling on the line
// (`flexBaseSize`/`dimensionsAt` per child) plus the container. If each of
// those measurements can re-enter flexItemWidth one level down, the cost of a
// read is multiplicative in the breadth, not additive -- and a page of nested
// flex rows is the ordinary shape of every retail homepage.
//
// So: k children per level, `depth` levels of nested `display:flex`, one
// `getBoundingClientRect` on the root, timed by the page itself. Doubling the
// depth of a linear engine adds a constant; here we are looking for the time to
// multiply by roughly k.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
// Output goes to results/, not next to the script: `here` is a tracked
// directory now and these rigs write tens of megabytes of engine log.
const outDir = path.join(here, 'results');
const arg = (k, d) => { const i = process.argv.indexOf(k); return i === -1 ? d : process.argv[i + 1]; };
const bin = arg('--bin', process.env.LP_BIN ?? path.join(repo, 'zig-out/bin/lightpanda'));
const PORT = Number(arg('--port', 9253));
const HTTP_PORT = PORT + 1;
const K = Number(arg('--k', 3));
const depths = String(arg('--depths', '1,2,3,4,5,6,7,8')).split(',').map(Number);

// One page shape, two knobs. `flex` is the treatment; `block` is the control
// with an identical tree, so a curve that bends on both is about tree size and
// a curve that bends only on flex is about the flex path.
function page(depth, k, mode) {
    const build = (d) => d === 0
        ? '<span>word</span>'
        : `<div class="box">${Array.from({ length: k }, () => build(d - 1)).join('')}</div>`;
    // flex        -- growing items, so flexItemWidth takes its sibling walk
    // flex-nogrow -- same flex containers, `flex-grow: 0`, which returns from
    //                flexItemWidth before the walk. Separates "flex" from
    //                "the walk over every sibling on the line".
    // block       -- identical tree, no flex path at all.
    const display = mode === 'block' ? 'block' : 'flex';
    const grow = mode === 'flex' ? 1 : 0;
    return `<!doctype html><meta charset=utf-8><style>
  .box { display: ${display}; flex-grow: ${grow}; padding: 1px; }
</style><body><div id=root class=box>${build(depth)}</div>
<script>
  var el = document.getElementById('root');
  var a = performance.now();
  var r = el.getBoundingClientRect();
  window.__cost = { ms: performance.now() - a, width: r.width, height: r.height,
                    nodes: document.querySelectorAll('div').length };
</script></body>`;
}

let wanted = null;
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(wanted ?? '<!doctype html><body>no page');
});
await new Promise((r) => server.listen(HTTP_PORT, '127.0.0.1', r));

const proc = spawn(bin, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
const engineLog = [];
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));

const rows = [];
try {
    for (let i = 0; i < 60; i++) {
        try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(250); }
    }
    for (const mode of ['flex', 'flex-nogrow', 'block']) {
        for (const depth of depths) {
            wanted = page(depth, K, mode);
            // A fresh page per reading: the caches this engine keeps are keyed
            // on the document, and a warm one would answer the second half of
            // the curve from the first half's work.
            const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
            const { sessionId } = await newPage(cdp);
            const started = Date.now();
            let cost = null;
            try {
                await cdp.send('Page.navigate', { url: `http://127.0.0.1:${HTTP_PORT}/` }, sessionId);
                await sleep(300);
                cost = await evaluate(cdp, sessionId, 'window.__cost');
            } catch (e) {
                cost = { error: String(e.message ?? e).slice(0, 120) };
            }
            const wall = Date.now() - started;
            cdp.close();
            const row = { mode, depth, k: K, wall, ...(cost ?? { error: 'no reading' }) };
            rows.push(row);
            console.log(`${mode.padEnd(5)} depth=${String(depth).padStart(2)} k=${K} ` +
                `nodes=${String(row.nodes ?? '-').padStart(6)} ` +
                `rect=${row.ms === undefined ? `ERR ${row.error}` : `${row.ms.toFixed(2)}ms`} wall=${wall}ms`);
            if (row.ms !== undefined && row.ms > 20000) { console.log('  (over 20s, stopping this arm)'); break; }
            if (row.error) break;
        }
    }
} finally {
    proc.kill('SIGKILL');
    server.close();
    await fs.writeFile(path.join(outDir, `flex-cost-k${K}.json`), JSON.stringify({ bin, K, rows, engineLogTail: engineLog.join('').split('\n').filter(Boolean).slice(-40) }, null, 2) + '\n');
    console.log(`wrote tools/fingerprint/results/flex-cost-k${K}.json`);
    process.exit(0);
}
