// Long-running memory soak for the crawl service: a closed-loop mixed load
// through POST /crawl, with the container's and the engine's memory sampled
// on a fixed interval. Run on the Docker host, next to the container.
//
//   node soak.mjs --target http://IP:8080 --container NAME \
//     --pages http://172.17.0.1:29790 -c 20 \
//     --mix hn=50,wiki=15,js=20,throw=3,hang=4,hangdoc=3,refused=5 \
//     --phases load:120m,idle:15m,load:30m --sample 30 --out soak.jsonl
//
// Every sample is one JSON line: requests done so far (total and per class,
// per status), the container cgroup's memory (current, anon, file), the
// engine's /proc status and smaps_rollup, its thread and fd counts, the Node
// service's RSS, and /health's reconnects. `idle` phases stop the load and
// keep sampling, to see whether memory comes back.
//
// Classes (pages come from pagesrv.mjs):
//   hn       small page, html + meta
//   wiki     395 KB page, html + meta
//   js       small page plus a script that builds 2,000 DOM nodes, eval + markdown
//   throw    small page plus a script that throws (still a 200)
//   hang     page whose async script never arrives: 504 after `--hang-timeout`,
//            partial html, connection discarded
//   hangdoc  main document never answers: 504, connection discarded
//   refused  a closed port: 502 navigation_failed
//   spin     page stuck in `for(;;)` until the engine's watchdog (weight 0 by default)
//   hnmin    hn with html only (no meta: no location/title evaluate, no cookies)
//   empty    a page with no script, stylesheet or image, html only
//   ev       small page plus a script that makes 1,000 `Event`s and keeps them
//            alive until the page is torn down (a type with a finalizer: one
//            fc_identity_pool record each)
//   evgc     the same 1,000 `Event`s, dropped at once (V8 may collect them first)

import { execFile } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { parseArgs } from 'node:util';

const { values: o } = parseArgs({
    options: {
        target: { type: 'string' },
        container: { type: 'string' },
        pages: { type: 'string', default: 'http://172.17.0.1:29790' },
        refused: { type: 'string', default: 'http://172.17.0.1:1/' },
        c: { type: 'string', default: '20' },
        mix: { type: 'string', default: 'hn=50,wiki=15,js=20,throw=3,hang=4,hangdoc=3,refused=5' },
        phases: { type: 'string', default: 'load:120m' },
        sample: { type: 'string', default: '30' },
        'hang-timeout': { type: 'string', default: '3000' },
        out: { type: 'string', default: 'soak.jsonl' },
        label: { type: 'string', default: '' },
    },
});

const JS_DOM = `(async () => {
  const root = document.createElement('div');
  for (let i = 0; i < 2000; i++) {
    const s = document.createElement('span');
    s.textContent = 'n' + i;
    s.setAttribute('data-i', i);
    root.appendChild(s);
  }
  document.body.appendChild(root);
  const a = [];
  for (let i = 0; i < 20000; i++) a.push({ i, s: 'x' + i });
  await new Promise((r) => setTimeout(r, 5));
  return document.querySelectorAll('span[data-i]').length + a.length;
})()`;

const P = o.pages;
const hangTimeout = +o['hang-timeout'];
const CLASSES = {
    hn: { url: `${P}/hn.html` },
    wiki: { url: `${P}/wiki.html` },
    js: { url: `${P}/hn.html`, js: JS_DOM, formats: ['eval', 'markdown', 'meta'] },
    throw: { url: `${P}/hn.html`, js: '(() => { throw new Error("soak") })()' },
    hang: { url: `${P}/hang.html`, timeout: hangTimeout },
    hangdoc: { url: `${P}/hang`, timeout: hangTimeout },
    refused: { url: o.refused },
    spin: { url: `${P}/spin.html`, timeout: hangTimeout },
    hnmin: { url: `${P}/hn.html`, formats: ['html'] },
    empty: { url: `${P}/empty.html`, formats: ['html'] },
    ev: { url: `${P}/hn.html`, js: 'window.__keep = Array.from({ length: 1000 }, () => new Event("x")).length', formats: ['eval', 'meta'] },
    evgc: { url: `${P}/hn.html`, js: '(() => { let n = 0; for (let i = 0; i < 1000; i++) n += new Event("x").bubbles ? 1 : 0; return n })()', formats: ['eval', 'meta'] },
};

const mix = o.mix.split(',').map((kv) => {
    const [k, w] = kv.split('=');
    if (!CLASSES[k]) throw new Error(`unknown class ${k}`);
    return [k, +w];
}).filter(([, w]) => w > 0);
const totalW = mix.reduce((s, [, w]) => s + w, 0);
function pick() {
    let r = Math.random() * totalW;
    for (const [k, w] of mix) if ((r -= w) < 0) return k;
    return mix[mix.length - 1][0];
}

const phases = o.phases.split(',').map((p) => {
    const [kind, d] = p.split(':');
    const m = /^(\d+(?:\.\d+)?)([smh])$/.exec(d);
    if (!['load', 'idle'].includes(kind) || !m) throw new Error(`bad phase ${p}`);
    return { kind, ms: +m[1] * { s: 1e3, m: 60e3, h: 3600e3 }[m[2]] };
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const counts = {}; // class -> status -> n
let done = 0;
let running = false;
let stopping = false;

async function worker() {
    while (!stopping) {
        if (!running) {
            await sleep(200);
            continue;
        }
        const cls = pick();
        const body = JSON.stringify(CLASSES[cls]);
        let status;
        try {
            const r = await fetch(`${o.target}/crawl`, { method: 'POST', body, headers: { 'content-type': 'application/json' } });
            const j = await r.json().catch(() => null);
            status = r.status === 200 ? '200' : `${r.status}:${j?.error?.code ?? '?'}`;
        } catch (e) {
            status = `fetch:${e.cause?.code ?? e.message}`;
            await sleep(500);
        }
        const c = (counts[cls] ??= {});
        c[status] = (c[status] ?? 0) + 1;
        done++;
    }
}

// --- sampling -------------------------------------------------------------

function cgroupDir(name) {
    const id = execFileSync('docker', ['inspect', '-f', '{{.Id}}', name]).toString().trim();
    for (const d of [`/sys/fs/cgroup/system.slice/docker-${id}.scope`, `/sys/fs/cgroup/docker/${id}`]) if (fs.existsSync(d)) return d;
    throw new Error(`no cgroup dir for ${name}`);
}
const cg = cgroupDir(o.container);
const KB = (s, k) => {
    const m = new RegExp(`^${k}:\\s+(\\d+)`, 'm').exec(s);
    return m ? +m[1] : null;
};

// One docker exec per sample: the engine's status and smaps_rollup need
// ptrace access to a root process, which the host user doesn't have.
// VmRSS in /proc/<pid>/status is a per-CPU counter read without summing (since
// Linux 6.2); on a 512-core host it is off by tens of MB (tini reads 0, Node
// a round 40960 kB). smaps_rollup walks the page tables and is exact, so the
// RSS figures below come from it.
const PROBE = `p=$(cat /tmp/lightpanda.pid); echo "PID $p"; cat /proc/$p/status; echo ROLLUP; cat /proc/$p/smaps_rollup; echo "FDS $(ls /proc/$p/fd | wc -l)"; for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = node ] && { echo NODE; cat $d/smaps_rollup; }; done; echo METRICS; node -e 'fetch("http://127.0.0.1:"+(process.env.LP_PORT||9222)+"/metrics").then(r=>r.text()).then(t=>process.stdout.write(t))' 2>/dev/null; true`;
function probe() {
    return new Promise((resolve) => {
        execFile('docker', ['exec', o.container, 'sh', '-c', PROBE], { timeout: 20000, maxBuffer: 1 << 20 }, (err, out) => resolve(err ? null : out.toString()));
    });
}

async function sample(phase) {
    const out = await probe();
    let engine = null, node = null, lpMetrics = null;
    if (out) {
        const [procs, metrics = ''] = out.split('\nMETRICS\n');
        const [eng, nodePart = ''] = procs.split('\nNODE\n');
        const metric = (k) => {
            const m = new RegExp(`^${k} (\\d+)`, 'm').exec(metrics);
            return m ? +m[1] : null;
        };
        lpMetrics = { jsHeapPhysical: metric('js_heap_physical_bytes'), arenaBytes: metric('arena_memory_bytes'), navigations: metric('navigate_total\\{type="page"\\}') };
        const [status, rollup = ''] = eng.split('\nROLLUP\n');
        engine = {
            pid: +/^PID (\d+)/.exec(status)?.[1],
            rssKB: KB(rollup, 'Rss'),
            anonKB: KB(rollup, 'Anonymous'),
            statusRssKB: KB(status, 'VmRSS'),
            hwmKB: KB(status, 'VmHWM'),
            threads: KB(status, 'Threads'),
            fds: +/FDS (\d+)/.exec(rollup)?.[1],
            pssKB: KB(rollup, 'Pss'),
            pssAnonKB: KB(rollup, 'Pss_Anon'),
            privDirtyKB: KB(rollup, 'Private_Dirty'),
        };
        node = { rssKB: KB(nodePart, 'Rss'), anonKB: KB(nodePart, 'Anonymous') };
    }
    const stat = fs.readFileSync(`${cg}/memory.stat`, 'utf8');
    const st = (k) => +new RegExp(`^${k} (\\d+)`, 'm').exec(stat)?.[1];
    let health = null;
    try {
        health = (await (await fetch(`${o.target}/health`, { signal: AbortSignal.timeout(5000) })).json()).pool;
    } catch {}
    const line = {
        label: o.label,
        t: Math.round((Date.now() - t0) / 1000),
        phase,
        done,
        counts,
        cg: { currentMB: +fs.readFileSync(`${cg}/memory.current`, 'utf8') / 2 ** 20, anonMB: st('anon') / 2 ** 20, fileMB: st('file') / 2 ** 20 },
        engine,
        node,
        metrics: lpMetrics,
        reconnects: health?.reconnects ?? null,
        load: +fs.readFileSync('/proc/loadavg', 'utf8').split(' ')[0],
    };
    fs.appendFileSync(o.out, JSON.stringify(line) + '\n');
}

const sampleMs = +o.sample * 1000;
let phaseName = 'start';
const ticker = (async () => {
    while (!stopping) {
        await sample(phaseName);
        await sleep(sampleMs);
    }
})();

const workers = Array.from({ length: +o.c }, worker);
for (const [i, ph] of phases.entries()) {
    phaseName = `${i}:${ph.kind}`;
    running = ph.kind === 'load';
    console.error(`${new Date().toISOString()} phase ${phaseName} for ${ph.ms / 1000}s (done ${done})`);
    await sleep(ph.ms);
}
running = false;
stopping = true;
await Promise.all(workers);
phaseName = 'end';
await sample('end');
console.error(`${new Date().toISOString()} finished, ${done} requests`, JSON.stringify(counts));
await ticker.catch(() => {});
