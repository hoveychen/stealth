// Closed-loop load generator for the crawl service and its engine.
//
//   node service/bench/bench.mjs --mode service --target http://172.17.0.5:8080 \
//       --url http://172.17.0.1:29790/wiki.html -c 16 --container lp-crawl-p5
//
// Modes:
//   service  POST /crawl {url} to the service (default formats: html + meta)
//   cdp      the same crawl, run in this process with the service's own
//            Pool/crawl code against the engine's CDP port, so the difference
//            to `service` is the HTTP layer and the in-container Node process
//   http     plain GET of --url (measures the page server, not the engine)
//
// `-c` workers each loop request → response until the run ends. The first
// `--warmup` seconds are discarded; then the run continues until at least
// `--seconds` have passed and `--min-samples` loads finished, or `--max-seconds`.
// With --container, the container's cgroup (CPU, memory) and the engine
// process (CPU, threads) are sampled over the measured window; this needs to run on
// the Docker host. Prints one JSON object per run. --procs K spreads the
// workers over K child processes (needed past ~1000 crawls/s).

import { execFileSync, fork } from 'node:child_process';
import fs from 'node:fs';
import { crawl, normalizeRequest } from '../lib/crawl.mjs';
import { Pool } from '../lib/pool.mjs';

const args = Object.fromEntries(
    process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('-') ? [...acc, [a.replace(/^-+/, ''), all[i + 1]]] : acc), []),
);
const mode = args.mode ?? 'service';
const target = args.target;
const pageUrl = args.url;
const conc = +(args.c ?? 1);
const warmupS = +(args.warmup ?? 3);
const minS = +(args.seconds ?? 10);
const maxS = +(args['max-seconds'] ?? 60);
const minSamples = +(args['min-samples'] ?? 50);
const timeoutMs = +(args.timeout ?? 60000);
const container = args.container;
const label = args.label ?? '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const loadavg = () => fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).map(Number);

// --- sampling -------------------------------------------------------------

const TICK = 100; // USER_HZ
function cgroupDir(name) {
    const id = execFileSync('docker', ['inspect', '-f', '{{.Id}}', name]).toString().trim();
    for (const d of [`/sys/fs/cgroup/system.slice/docker-${id}.scope`, `/sys/fs/cgroup/docker/${id}`]) if (fs.existsSync(d)) return d;
    throw new Error(`no cgroup dir for ${name}`);
}
function containerPids(name) {
    const out = execFileSync('docker', ['top', name, '-eo', 'pid,comm']).toString().trim().split('\n').slice(1);
    const pids = {};
    for (const l of out) {
        const [pid, comm] = l.trim().split(/\s+/);
        pids[comm] = +pid;
    }
    return pids;
}
const cgCpuUs = (dir) => +/usage_usec (\d+)/.exec(fs.readFileSync(`${dir}/cpu.stat`, 'utf8'))[1];
const cgMem = (dir) => +fs.readFileSync(`${dir}/memory.current`, 'utf8');
function procCpuTicks(pid) {
    try {
        const f = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
        const rest = f.slice(f.lastIndexOf(')') + 2).split(' ');
        return +rest[11] + +rest[12]; // utime + stime
    } catch {
        return NaN;
    }
}
function procThreads(pid) {
    try {
        return +/Threads:\s+(\d+)/.exec(fs.readFileSync(`/proc/${pid}/status`, 'utf8'))[1];
    } catch {
        return NaN;
    }
}

class Sampler {
    constructor(name) {
        this.dir = cgroupDir(name);
        this.pids = containerPids(name);
        this.engine = this.pids.lightpanda;
        this.node = this.pids.node;
        this.peakMem = 0;
        this.peakThreads = 0;
        this.baseMem = cgMem(this.dir);
        this.timer = setInterval(() => this.tick(), 200);
        this.tick();
    }
    tick() {
        this.peakMem = Math.max(this.peakMem, cgMem(this.dir));
        this.peakThreads = Math.max(this.peakThreads, procThreads(this.engine) || 0);
    }
    mark() {
        return { t: performance.now(), cg: cgCpuUs(this.dir), eng: procCpuTicks(this.engine), node: procCpuTicks(this.node), self: process.cpuUsage() };
    }
    resetPeaks() {
        this.peakMem = this.peakThreads = 0;
        this.tick();
    }
    stop() {
        clearInterval(this.timer);
    }
}

// --- one load per mode ----------------------------------------------------

let pool;
async function loadOnce() {
    if (mode === 'http') {
        const r = await fetch(pageUrl, { signal: AbortSignal.timeout(timeoutMs) });
        const b = await r.arrayBuffer();
        if (r.status !== 200) throw new Error(`http ${r.status}`);
        return b.byteLength;
    }
    if (mode === 'service') {
        const r = await fetch(`${target}/crawl`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ url: pageUrl, timeout: timeoutMs }),
            signal: AbortSignal.timeout(timeoutMs + 5000),
        });
        const j = await r.json();
        if (r.status !== 200) throw new Error(`${r.status} ${j.error?.code}: ${j.error?.message}`);
        if (j.meta?.status !== 200) throw new Error(`page status ${j.meta?.status}`);
        return j.html.length;
    }
    if (mode === 'cdp') {
        const req = normalizeRequest({ url: pageUrl, timeout: timeoutMs }, { defaultTimeoutMs: timeoutMs, maxTimeoutMs: timeoutMs });
        const out = await crawl(pool, req, { proxies: null, sessions: null, partialGraceMs: 0 });
        if (out.meta?.status !== 200) throw new Error(`page status ${out.meta?.status}`);
        return out.html.length;
    }
    throw new Error(`unknown mode ${mode}`);
}

// --- run ------------------------------------------------------------------
//
// With --procs K the workers are split over K child processes: one Node
// thread tops out around a thousand small crawls a second, and past that the
// load generator, not the engine, sets the ceiling. The parent only samples
// and steers the phases.

const procs = Math.max(1, Math.min(+(args.procs ?? 1), conc));
const isChild = !!process.env.BENCH_CHILD;

// Local workers: `start` begins warmup, `measure` starts recording, `finish`
// stops and returns what was recorded.
function localRunner(n) {
    if (mode === 'cdp') {
        // Not /json/version's webSocketDebuggerUrl: that names the engine's own
        // listen address, which inside a container is not the one we can reach.
        const ws = target.replace(/^http/, 'ws').replace(/\/?$/, '/');
        pool = new Pool({ cdpUrl: ws, size: n, queueMax: 1000, connectTimeoutMs: 10000 });
    }
    let phase = 'warmup';
    const lat = [];
    const errors = {};
    let errCount = 0;
    let warmLoads = 0;
    let cpu0;
    async function worker() {
        while (phase !== 'done') {
            const t = performance.now();
            const ph = phase;
            try {
                await loadOnce();
                if (ph === 'measure' && phase === 'measure') lat.push(performance.now() - t);
                else warmLoads++;
            } catch (e) {
                if (ph === 'measure' && phase === 'measure') {
                    errCount++;
                    const k = String(e.message).slice(0, 120);
                    errors[k] = (errors[k] ?? 0) + 1;
                }
                await sleep(50);
            }
        }
    }
    const workers = Array.from({ length: n }, () => worker());
    return {
        measure() {
            cpu0 = process.cpuUsage();
            phase = 'measure';
        },
        count: () => lat.length + errCount,
        async finish() {
            phase = 'done';
            const cpu = process.cpuUsage(cpu0);
            const out = { lat: lat.slice(), errors, errCount, warmLoads, cpuUs: cpu.user + cpu.system };
            await Promise.race([Promise.all(workers), sleep(timeoutMs + 6000)]);
            return out;
        },
    };
}

function childRunner(n) {
    const child = fork(new URL(import.meta.url).pathname, process.argv.slice(2).concat(['-c', String(n)]), { env: { ...process.env, BENCH_CHILD: '1' } });
    let count = 0;
    let result;
    child.on('message', (m) => {
        if (m.count !== undefined) count = m.count;
        if (m.result) result(m.result);
    });
    return {
        measure: () => child.send('measure'),
        count: () => count,
        finish: () => new Promise((resolve) => ((result = resolve), child.send('done'))),
    };
}

if (isChild) {
    const r = localRunner(conc);
    process.on('message', async (m) => {
        if (m === 'measure') r.measure();
        if (m === 'done') {
            // Exit only once the result is flushed: a long run's latency array is
            // larger than the IPC pipe buffer and exiting right away drops it,
            // leaving the parent waiting forever.
            process.send({ result: await r.finish() }, () => process.exit(0));
        }
    });
    setInterval(() => process.send({ count: r.count() }), 200);
} else {
    const runners =
        procs > 1
            ? Array.from({ length: procs }, (_, i) => childRunner(Math.floor(conc / procs) + (i < conc % procs ? 1 : 0)))
            : [localRunner(conc)];
    const sampler = container ? new Sampler(container) : null;
    const load0 = loadavg();
    await sleep(warmupS * 1000);
    sampler?.resetPeaks();
    const m0 = sampler?.mark();
    const self0 = process.cpuUsage();
    const measureStart = performance.now();
    for (const r of runners) r.measure();
    const total = () => runners.reduce((a, r) => a + r.count(), 0);
    for (;;) {
        await sleep(200);
        const el = (performance.now() - measureStart) / 1000;
        if ((el >= minS && total() >= minSamples) || el >= maxS) break;
    }
    const m1 = sampler?.mark();
    const wall = (performance.now() - measureStart) / 1000;
    const load1 = loadavg();
    const selfCpu = process.cpuUsage(self0);
    const outs = await Promise.all(runners.map((r) => r.finish()));
    sampler?.stop();

    // Loads that finish after the window closes are dropped by the local
    // runner; a child may still record one in flight, which is negligible
    // against thousands of samples.
    const lat = outs.flatMap((o) => o.lat).sort((a, b) => a - b);
    const errors = {};
    for (const o of outs) for (const [k, v] of Object.entries(o.errors)) errors[k] = (errors[k] ?? 0) + v;
    const errCount = outs.reduce((a, o) => a + o.errCount, 0);
    const clientUs = outs.reduce((a, o) => a + o.cpuUs, 0) + (procs > 1 ? selfCpu.user + selfCpu.system : 0);
    const q = (p) => (lat.length ? Math.round(lat[Math.min(lat.length - 1, Math.floor(p * lat.length))]) : null);
    const res = {
        label,
        mode,
        page: pageUrl.split('/').pop(),
        c: conc,
        procs,
        loads: lat.length,
        errors: errCount,
        errorKinds: errors,
        seconds: +wall.toFixed(2),
        pagesPerSec: +(lat.length / wall).toFixed(2),
        p50: q(0.5),
        p95: q(0.95),
        max: lat.length ? Math.round(lat[lat.length - 1]) : null,
        mean: lat.length ? Math.round(lat.reduce((a, b) => a + b, 0) / lat.length) : null,
        load: [load0[0], load1[0]],
        // Per process: above ~0.9 the load generator is the bottleneck.
        clientCoresPerProc: +(clientUs / 1e6 / wall / procs).toFixed(2),
        warmLoads: outs.reduce((a, o) => a + o.warmLoads, 0),
    };
    if (sampler) {
        const dt = (m1.t - m0.t) / 1000;
        Object.assign(res, {
            containerCores: +((m1.cg - m0.cg) / 1e6 / dt).toFixed(2),
            engineCores: +((m1.eng - m0.eng) / TICK / dt).toFixed(2),
            nodeCores: +((m1.node - m0.node) / TICK / dt).toFixed(2),
            startContainerMB: Math.round(sampler.baseMem / 2 ** 20),
            peakContainerMB: Math.round(sampler.peakMem / 2 ** 20),
            peakEngineThreads: sampler.peakThreads,
            engineStillUp: !Number.isNaN(procCpuTicks(sampler.engine)),
        });
    }
    console.log(JSON.stringify(res));
    process.exit(0);
}
