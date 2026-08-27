// Regenerates src/browser/webapi/audio/chrome_audio*.bin and chrome_audio.zig
// from real Chrome, on both platforms this engine can claim to be.
//
//   node tools/fingerprint/dump-audio-buffer.mjs [--headed]
//
// G10 established that the canonical audio fingerprint cannot be computed --
// it is a function of the host's FFT and libm, not of the spec -- so the only
// way to answer a detector with a real number is to record one. macOS comes
// from the Chrome installed here; Linux comes from the official amd64 package
// in a container (see linux-chrome.mjs, which explains why emulation is safe
// for this particular measurement).
//
// This writes raw little-endian f32 rather than Zig float literals: the tail
// sum a detector hashes moves with a single ULP, and a decimal round-trip
// through source text is exactly the kind of place a ULP goes missing.
//
// There is more than one graph to record. fingerprintjs's is the one every
// clone builds, and for a long time it was assumed to be the only one worth
// answering. It is not: audio-graph-trace.mjs watched the Cloudflare Turnstile
// widget build its own on the live station, and it is fingerprintjs's shape
// with three of the numbers moved -- a tone at 9 998.123456 Hz, a -52 dB
// threshold and a 0.0001 s attack. Its render reproduces the vector three
// separate sittings recorded off the station, to a maximum difference of zero.
// Nothing about the recording generalises across those numbers, so each graph
// is recorded in full, per platform.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';
import { withLinuxChrome } from './linux-chrome.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const outDir = path.join(repo, 'src/browser/webapi/audio');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const headed = process.argv.includes('--headed');
// One second. fingerprintjs reads 5 000 frames and the Turnstile widget 1 000,
// but Kasada renders the whole second on x-hyatt -- traced live by
// probes/inject-b83-audio-render.js -- and a recording shorter than the render
// is answered with zeros past its end, which is a buffer no Chrome produces.
// Recording the longest length any station has been seen asking for costs
// 176 400 bytes per graph per platform and removes the whole class.
const FRAMES = 44100;
const SAMPLE_RATE = 44100;

// The graphs worth recording. `zig` is the enum tag the generated file uses;
// everything else is what the page writes into the graph.
//
// The two differ only in three numbers, which is exactly why both are here: a
// render is not a continuous function of its settings that a stored buffer
// could be nudged along. `canonical_render.zig` decides which of these a page
// built by comparing all of them, so a graph that is neither still gets
// silence.
const GRAPHS = [
  { zig: 'fingerprintjs', who: "every fingerprintjs clone's",
    frequency: 10000, threshold: -50, knee: 40, ratio: 12, attack: 0, release: 0.25 },
  { zig: 'turnstile', who: "the Cloudflare Turnstile widget's",
    frequency: 9998.123456, threshold: -52, knee: 40, ratio: 12, attack: 0.0001, release: 0.25 },
];

// Kept as one string per graph so both engines are asked exactly the same
// question. `length` is a parameter rather than a constant because the prefix
// claim in the generated header is checked rather than assumed: the widget asks
// for 1 000 frames and this records 5 000, which is only sound if the shorter
// render is the longer one's prefix.
const probe = (g, frames) => `(async () => {
  const ctx = new OfflineAudioContext(1, ${frames}, ${SAMPLE_RATE});
  const osc = ctx.createOscillator();
  osc.type = 'triangle';
  osc.frequency.value = ${g.frequency};
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = ${g.threshold};
  comp.knee.value = ${g.knee};
  comp.ratio.value = ${g.ratio};
  comp.attack.value = ${g.attack};
  comp.release.value = ${g.release};
  osc.connect(comp);
  comp.connect(ctx.destination);
  osc.start(0);
  const d = (await ctx.startRendering()).getChannelData(0);
  let sum = 0;
  for (let i = ${frames} - 500; i < ${frames}; i++) sum += Math.abs(d[i]);
  let lead = 0;
  while (lead < d.length && d[lead] === 0) lead++;
  const bytes = new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return JSON.stringify({ ua: navigator.userAgent, tailSum: String(sum), leadingZeros: lead, b64: btoa(s) });
})()`;

const PREFIX_FRAMES = 1000;

async function measure(endpoint) {
  const cdp = await Cdp.connect(endpoint);
  try {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const run = async (expression) => {
      const res = await cdp.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
      if (res.exceptionDetails) throw new Error(res.exceptionDetails.exception?.description ?? res.exceptionDetails.text);
      return JSON.parse(res.result.value);
    };
    const out = {};
    for (const g of GRAPHS) {
      const full = await run(probe(g, FRAMES));
      const short = await run(probe(g, PREFIX_FRAMES));
      const a = Buffer.from(full.b64, 'base64').subarray(0, PREFIX_FRAMES * 4);
      const b = Buffer.from(short.b64, 'base64');
      if (!a.equals(b)) {
        throw new Error(`${g.zig}: a ${PREFIX_FRAMES}-frame render is not the ${FRAMES}-frame one's prefix`);
      }
      out[g.zig] = full;
    }
    return out;
  } finally {
    cdp.close();
  }
}

// --- macOS: the Chrome installed on this machine ------------------------------
const PORT = 9463;
const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-audio-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`, '--no-first-run', '--no-default-browser-check'];
if (!headed) flags.push('--headless=new');
const chrome = spawn(CHROME, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
chrome.stdout.resume();
chrome.stderr.resume();
for (let i = 0; i < 200; i++) {
  try {
    await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
    break;
  } catch {
    await sleep(200);
  }
}
let macos;
try {
  macos = await measure(`http://127.0.0.1:${PORT}`);
} finally {
  chrome.kill('SIGKILL');
  await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}
for (const g of GRAPHS) console.log(`macos  ${g.zig}  tailSum=${macos[g.zig].tailSum} leadingZeros=${macos[g.zig].leadingZeros}`);

// --- Linux: the official amd64 package, in a container ------------------------
const linux = await withLinuxChrome(async (endpoint, version) => {
  console.log(`linux  container is ${version.Browser}`);
  return measure(endpoint);
});
for (const g of GRAPHS) console.log(`linux  ${g.zig}  tailSum=${linux[g.zig].tailSum} leadingZeros=${linux[g.zig].leadingZeros}`);

const written = [];
for (const [name, arm] of [['macos', macos], ['linux', linux]]) {
  for (const g of GRAPHS) {
    const buf = Buffer.from(arm[g.zig].b64, 'base64');
    if (buf.length !== FRAMES * 4) throw new Error(`${name}/${g.zig}: expected ${FRAMES * 4} bytes, got ${buf.length}`);
    const file = `chrome_audio_${g.zig}_${name}.bin`;
    await fs.writeFile(path.join(outDir, file), buf);
    written.push(file);
  }
}

const describe = (g) => `//   ${g.who}:
//     OfflineAudioContext(1, frames, ${SAMPLE_RATE})
//     OscillatorNode  type=triangle  frequency=${g.frequency}  start(0)
//       -> DynamicsCompressorNode  threshold=${g.threshold} knee=${g.knee} ratio=${g.ratio} attack=${g.attack} release=${g.release}
//         -> destination
//     macos  tail sum over the last 500 frames = ${macos[g.zig].tailSum}, ${macos[g.zig].leadingZeros} leading zeros
//     linux  tail sum over the last 500 frames = ${linux[g.zig].tailSum}, ${linux[g.zig].leadingZeros} leading zeros`;

const zig = `// GENERATED by tools/fingerprint/dump-audio-buffer.mjs — do not hand-edit.
//
// The canonical audio fingerprints, recorded rather than computed. G10 (see
// tools/fingerprint/README.md) established that these renders cannot be
// derived: the wavetable comes from 36 inverse FFTs backed by vDSP on macOS and
// PFFFT everywhere else, and the compressor's inner loop calls the platform's
// libm per sample. There is no "Chrome" answer, only one answer per platform,
// so G21 stores what each platform actually produced.
//
// The graphs:
//
${GRAPHS.map(describe).join('\n//\n')}
//
// Two facts measured alongside the buffers make one stored table per graph
// enough:
//   * a ${PREFIX_FRAMES}-frame render is frame-for-frame identical to a ${FRAMES}-frame one over
//     the frames they share -- checked on every run of the generator, for every
//     graph -- so any length a detector picks is a prefix;
//   * the leading zeros above are the compressor's 6 ms pre-delay at ${SAMPLE_RATE} Hz.
//
// Recorded from:
//   macos  ${macos[GRAPHS[0].zig].ua}
//   linux  ${linux[GRAPHS[0].zig].ua}
//
// The bytes are little-endian f32, which is the only layout either recorded
// platform uses.

pub const Platform = enum { macos, linux };

/// The graphs with a recorded render of their own. A page that builds anything
/// else gets silence, because there is nothing honest to hand it.
pub const Graph = enum { ${GRAPHS.map((g) => g.zig).join(', ')} };

/// What a page has to have written for a graph to be that one. Compared in
/// full: two of these differ by three numbers and render nothing alike.
pub const Settings = struct {
    frequency: f64,
    threshold: f64,
    knee: f64,
    ratio: f64,
    attack: f64,
    release: f64,
};

pub fn settings(graph: Graph) Settings {
    return switch (graph) {
${GRAPHS.map((g) => `        .${g.zig} => .{ .frequency = ${g.frequency}, .threshold = ${g.threshold}, .knee = ${g.knee}, .ratio = ${g.ratio}, .attack = ${g.attack}, .release = ${g.release} },`).join('\n')}
    };
}

pub const sample_rate: f64 = ${SAMPLE_RATE};
pub const frames: usize = ${FRAMES};

${GRAPHS.map((g) => ['macos', 'linux'].map((pl) =>
  `const ${g.zig}_${pl}_bytes align(4) = @embedFile("chrome_audio_${g.zig}_${pl}.bin").*;`).join('\n')).join('\n')}

/// The recorded render for one graph on one platform, as the destination
/// channel data.
pub fn samples(graph: Graph, platform: Platform) *const [frames]f32 {
    return switch (graph) {
${GRAPHS.map((g) => `        .${g.zig} => switch (platform) {
            .macos => @ptrCast(&${g.zig}_macos_bytes),
            .linux => @ptrCast(&${g.zig}_linux_bytes),
        },`).join('\n')}
    };
}
`;

await fs.writeFile(path.join(outDir, 'chrome_audio.zig'), zig);
console.log(`wrote ${outDir}/chrome_audio.zig and ${written.join(', ')}`);
