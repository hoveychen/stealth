// Which audio graph did the widget build? Solve for it against its own bytes.
//
// The widget sends 1 000 `|`-joined floats and we send 1 000 zeros, because
// `canonical_render.matches()` refuses a graph it does not recognise and falls
// back to silence (see src/browser/webapi/audio/canonical_render.zig). Knowing
// *which* predicate refused needs the widget's actual construction — and the
// obvious way to get that is to trace the live station, which costs a sitting
// and a station that is in the mood.
//
// It is not the only way. Three sittings already on disk (p4b/p5/p6-oracle.json)
// carry the oracle's vector and it is byte-identical in all three, so the graph
// is deterministic and its render is a fixed target. Compared against
// chrome_audio_macos.bin over the same 1 000 frames:
//
//   * the 265 leading zeros match exactly -- 6 ms of compressor pre-delay at
//     44 100 Hz, so the sample rate is the canonical one;
//   * all 333 zero crossings land on the same sample indices -- so the source is
//     the same triangle at the same frequency with the same phase;
//   * only the envelope differs, by a smooth factor that drifts 1.048 -> 1.037.
//
// A drifting envelope over an identical waveform is the compressor's gain
// reduction and nothing else. So the remaining unknown is a handful of numbers,
// and numbers can be searched: render candidate graphs in the same real Chrome
// the recording came from and keep the one whose 1 000 frames are the oracle's.
//
// Scoring happens inside the page, not here -- 4 000 candidate renders is 4 000
// buffers, and shipping them over CDP to compare in node would cost more than
// the search.
//
// usage:
//   node tools/fingerprint/audio-graph-solve.mjs [--oracle results/p4b-oracle.json]
//        [--round 1|2] [--headed]
// env: CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};

const ORACLE = arg('--oracle', 'results/p4b-oracle.json');
const ROUND = Number(arg('--round', '1'));
const PORT = Number(arg('--port', '9464'));
const BATCH = Number(arg('--batch', '150'));
// Where to write the closest candidate's own samples, and how many of them.
const DUMP = arg('--dump', null);
const DUMP_FRAMES = Number(arg('--dump-frames', '5000'));
const headed = process.argv.includes('--headed');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const FRAMES = 1000;
const SAMPLE_RATE = 44100;

// --- the target -------------------------------------------------------------

// The recorder wraps TextEncoder.encode and crypto.subtle.digest, so the same
// vector shows up several times per sitting. Any of them will do; they agree.
async function oracleVector(file) {
    const j = JSON.parse(await fs.readFile(path.resolve(REPO, 'tools/fingerprint', file), 'utf8'));
    for (const r of j.records ?? []) {
        const v = r.a?.v;
        if (typeof v !== 'string') continue;
        const parts = v.split('|');
        if (parts.length === FRAMES && parts.every((p) => p !== '' && Number.isFinite(Number(p)))) {
            return parts.map(Number);
        }
    }
    throw new Error(`no ${FRAMES}-value audio vector in ${file}`);
}
const target = await oracleVector(ORACLE);

// --- the candidates ---------------------------------------------------------

// fingerprintjs's five settings are the origin of the search, not a constraint
// on it: the point is to find which of them the widget wrote differently.
const FINGERPRINTJS = { threshold: -50, knee: 40, ratio: 12, attack: 0, release: 0.25, gain: 1, frequency: 10000, type: 'triangle', rate: SAMPLE_RATE };
// The search origin starts there and moves; the control below always uses
// FINGERPRINTJS, which is the graph chrome_audio_macos.bin was recorded for.
const CANONICAL = { ...FINGERPRINTJS };

// Past round 3 the search stops being a story and starts being refinement,
// which wants an axis per invocation rather than an edit per invocation.
// `--base` moves the origin every candidate is built from and `--axes` crosses
// whatever it is given -- crosses, not walks, so two axes of ten are a hundred
// renders and not twenty:
//
//   node audio-graph-solve.mjs --base '{"ratio":20}' --axes '{"frequency":[…]}'
Object.assign(CANONICAL, JSON.parse(arg('--base', '{}')));
const AXES = arg('--axes', null);
// `--descend '["frequency","release"]'` runs coordinate descent from `--base`
// over those axes instead of (or as well as) a grid.
const DESCEND = arg('--descend', null);

function grid(axes) {
    let out = [{ ...CANONICAL }];
    for (const [key, values] of Object.entries(axes)) {
        const next = [];
        for (const base of out) for (const v of values) next.push({ ...base, [key]: v });
        out = next;
    }
    // Distinct candidates only -- the axes overlap on the canonical value.
    const seen = new Set();
    return out.filter((c) => {
        const k = JSON.stringify(c);
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
    });
}

// Round 1 walks one axis at a time. A drifting envelope over an unchanged
// waveform says the difference is in the compressor's reduction, and each of
// these five moves it; `gain` is in because a gain node ahead of the compressor
// moves the reduction too, which a gain node behind it would not.
const ROUND_1 = [
    ...grid({ threshold: [-100, -80, -70, -60, -55, -50, -45, -40, -36, -30, -24, -20, -12, -6, 0] }),
    ...grid({ knee: [0, 5, 10, 15, 20, 25, 30, 35, 40, 45] }),
    ...grid({ ratio: [1, 1.5, 2, 3, 4, 6, 8, 10, 12, 16, 20] }),
    ...grid({ attack: [0, 0.001, 0.003, 0.005, 0.01, 0.02, 0.05, 0.1, 0.3, 1] }),
    ...grid({ release: [0, 0.01, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5, 1, 2] }),
    ...grid({ gain: [0.5, 0.8, 0.9, 0.95, 1, 1.05, 1.1, 1.2, 1.5, 2] }),
];

// Round 1 came back flat -- every compressor axis moved the error by less than
// a thousandth, which said the difference was not in the compressor at all.
// Fitting a sinusoid to both renders said what it is instead: our tone sits at
// exactly 10 000.000 Hz and the oracle's at 9 998.125, a phase that drifts
// linearly apart rather than an envelope that scales. Only two things can move
// a rendered tone's frequency -- what the oscillator was told, and how many
// samples a second the context counts -- so round 2 walks both. A tone measured
// per-sample cannot tell them apart, which is the point of asking Chrome
// instead of algebra.
const ROUND_2 = [
    ...grid({ frequency: Array.from({ length: 81 }, (_, i) => 9996 + i * 0.0625) }),
    ...grid({ rate: Array.from({ length: 81 }, (_, i) => 44060 + i) }),
];

// Round 3 re-walks the compressor at whatever frequency round 2 lands on. The
// amplitude gap (4.5 %, and closing) is a second difference from the first, and
// round 1 could not see it under the phase drift.
const ROUND_3_BASE = Number(arg('--frequency', '10000'));
const ROUND_3 = [
    ...grid({ frequency: [ROUND_3_BASE], threshold: [-100, -80, -70, -60, -55, -50, -45, -40, -36, -30, -24, -20, -12, -6, 0] }),
    ...grid({ frequency: [ROUND_3_BASE], knee: [0, 5, 10, 15, 20, 25, 30, 35, 40, 45] }),
    ...grid({ frequency: [ROUND_3_BASE], ratio: [1, 1.5, 2, 3, 4, 6, 8, 10, 12, 16, 20] }),
    ...grid({ frequency: [ROUND_3_BASE], attack: [0, 0.001, 0.003, 0.005, 0.01, 0.02, 0.05, 0.1, 0.3, 1] }),
    ...grid({ frequency: [ROUND_3_BASE], release: [0, 0.01, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5, 1, 2] }),
    ...grid({ frequency: [ROUND_3_BASE], gain: [0.5, 0.8, 0.9, 0.95, 1, 1.05, 1.1, 1.2, 1.5, 2] }),
    ...grid({ frequency: [ROUND_3_BASE], type: ['triangle', 'sine', 'square', 'sawtooth'] }),
];

// Rounds 1-3 are the trail as it was actually walked, kept so it can be walked
// again.
const candidates = AXES ? grid(JSON.parse(AXES)) : ({ 1: ROUND_1, 2: ROUND_2, 3: ROUND_3 }[ROUND] ?? ROUND_1);

// --- the page ---------------------------------------------------------------

// Renders one candidate and answers with how far its 1 000 frames are from the
// oracle's, so only a number per candidate crosses the wire.
const PRELUDE = `
globalThis.__target = null;
globalThis.__score = async function (c) {
  const ctx = new OfflineAudioContext(1, ${FRAMES}, c.rate);
  const osc = ctx.createOscillator();
  osc.type = c.type;
  osc.frequency.value = c.frequency;
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = c.threshold;
  comp.knee.value = c.knee;
  comp.ratio.value = c.ratio;
  comp.attack.value = c.attack;
  comp.release.value = c.release;
  if (c.gain === 1) {
    osc.connect(comp);
  } else {
    const g = ctx.createGain();
    g.gain.value = c.gain;
    osc.connect(g);
    g.connect(comp);
  }
  comp.connect(ctx.destination);
  osc.start(0);
  const d = (await ctx.startRendering()).getChannelData(0);
  const t = globalThis.__target;
  let max = 0, sum = 0;
  for (let i = 0; i < ${FRAMES}; i++) {
    const e = Math.abs(d[i] - t[i]);
    if (e > max) max = e;
    sum += e;
  }
  return { max: max, mean: sum / ${FRAMES}, exact: max === 0 };
};
globalThis.__batch = async function (list) {
  const out = [];
  for (const c of list) out.push(await globalThis.__score(c));
  return JSON.stringify(out);
};
// The winner's own samples, for the residual to be looked at rather than
// summarised. Base64 of the little-endian f32 the render already is -- the same
// layout dump-audio-buffer.mjs writes, and for the same reason: a decimal
// round-trip through source text is where a ULP goes missing.
globalThis.__render = async function (c, frames) {
  const ctx = new OfflineAudioContext(1, frames, c.rate);
  const osc = ctx.createOscillator();
  osc.type = c.type;
  osc.frequency.value = c.frequency;
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = c.threshold;
  comp.knee.value = c.knee;
  comp.ratio.value = c.ratio;
  comp.attack.value = c.attack;
  comp.release.value = c.release;
  if (c.gain === 1) { osc.connect(comp); }
  else { const g = ctx.createGain(); g.gain.value = c.gain; osc.connect(g); g.connect(comp); }
  comp.connect(ctx.destination);
  osc.start(0);
  const d = (await ctx.startRendering()).getChannelData(0);
  const b = new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
  let s = '';
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s);
};`;

// --- run --------------------------------------------------------------------

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'audio-solve-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags()];
if (!headed) flags.push('--headless=new');
const chrome = spawn(CHROME, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
chrome.stdout.resume();
chrome.stderr.resume();

let cdp = null;
let results = [];
try {
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); }
    }
    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    const evaluate = async (expression, awaitPromise = false) => {
        const r = await cdp.send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, sessionId);
        if (r.exceptionDetails) {
            throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
        }
        return r.result.value;
    };

    await evaluate(PRELUDE);
    await evaluate(`globalThis.__target = ${JSON.stringify(target)}; globalThis.__target.length`);

    // The control: the graph this engine already replays, scored against the
    // recording it replays. If this is not zero the harness is measuring
    // something other than what dump-audio-buffer.mjs recorded, and no result
    // below means anything.
    const bin = await fs.readFile(path.join(REPO, 'src/browser/webapi/audio/chrome_audio_macos.bin'));
    const recorded = Array.from(new Float32Array(bin.buffer, bin.byteOffset, FRAMES));
    await evaluate(`globalThis.__target = ${JSON.stringify(recorded)}; 0`);
    const control = JSON.parse(await evaluate(`globalThis.__batch(${JSON.stringify([FINGERPRINTJS])})`, true))[0];
    console.log(`control  canonical graph vs chrome_audio_macos.bin: max=${control.max} mean=${control.mean}`);
    if (!control.exact) console.log('  WARNING: the control is not exact, so nothing below is trustworthy');

    await evaluate(`globalThis.__target = ${JSON.stringify(target)}; 0`);

    // Coordinate descent, when a grid has taken the search as far as a grid can.
    // The stopping condition is not "close enough" -- it is `max === 0` over
    // 1 000 float32 samples, which no wrong graph reaches by luck. That is what
    // makes this identification rather than curve fitting, and it is the only
    // result `canonical_render.matches()` can be widened on: the predicate
    // compares exact doubles, so an approximate answer replays silence exactly
    // as it does today.
    if (DESCEND) {
        const step = { frequency: 1, rate: 4, threshold: 1, knee: 2, ratio: 1, attack: 0.002, release: 0.02, gain: 0.02 };
        const axes = JSON.parse(DESCEND);
        let at = { ...CANONICAL };
        const scoreOne = async (c) => JSON.parse(await evaluate(`globalThis.__batch(${JSON.stringify([c])})`, true))[0];
        let best = await scoreOne(at);
        console.log(`descend from max=${best.max}`);
        for (let pass = 0; pass < 60 && !best.exact; pass++) {
            let moved = false;
            for (const k of axes) {
                for (const dir of [1, -1]) {
                    const trial = { ...at, [k]: at[k] + dir * step[k] };
                    const s = await scoreOne(trial);
                    results.push({ ...trial, ...s });
                    if (s.max < best.max) { best = s; at = trial; moved = true; break; }
                }
            }
            if (!moved) {
                for (const k of axes) step[k] /= 2;
                if (axes.every((k) => step[k] < 1e-7)) break;
            }
            console.log(`  pass ${pass}: max=${best.max.toExponential(4)}  ${axes.map((k) => `${k}=${at[k]}`).join(' ')}`);
        }
        results.push({ ...at, ...best });
    }

    console.log(`round ${ROUND}: ${candidates.length} candidates`);
    for (let i = 0; i < candidates.length; i += BATCH) {
        const chunk = candidates.slice(i, i + BATCH);
        const scores = JSON.parse(await evaluate(`globalThis.__batch(${JSON.stringify(chunk)})`, true));
        for (const [j, s] of scores.entries()) results.push({ ...chunk[j], ...s });
        process.stdout.write(`\r  ${Math.min(i + BATCH, candidates.length)}/${candidates.length}`);
    }
    process.stdout.write('\n');

    if (DUMP) {
        const best = [...results].sort((a, b) => a.max - b.max)[0];
        const b64 = await evaluate(`globalThis.__render(${JSON.stringify(best)}, ${DUMP_FRAMES})`, true);
        // A bare name lands beside the other fingerprint artefacts; anything
        // with a path in it is taken as given.
        const out = DUMP.includes('/') ? path.resolve(DUMP) : path.join(HERE, DUMP);
        await fs.writeFile(out, Buffer.from(b64, 'base64'));
        console.log(`wrote ${out} (${DUMP_FRAMES} frames of the closest candidate)`);
    }
} finally {
    cdp?.close();
    chrome.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true }).catch(() => { });
}

results.sort((a, b) => a.max - b.max);
const show = (c) => `freq=${c.frequency} rate=${c.rate} type=${c.type} threshold=${c.threshold}`
    + ` knee=${c.knee} ratio=${c.ratio} attack=${c.attack} release=${c.release} gain=${c.gain}`;
console.log('\nclosest 15:');
for (const c of results.slice(0, 15)) {
    console.log(`  max=${c.max.toFixed(9)} mean=${c.mean.toFixed(9)}  ${show(c)}${c.exact ? '   *** EXACT ***' : ''}`);
}
const exact = results.filter((c) => c.exact);
console.log(exact.length ? `\nEXACT MATCH: ${show(exact[0])}` : '\nno exact match in this round');
