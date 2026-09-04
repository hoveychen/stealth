// browserscan.net, once per WEBGL_debug_renderer_info string.
//
// The hardware card stopped resolving when the engine started claiming macOS,
// and the obvious suspects were the two Apple strings that arrived with the
// claim. They are not the cause. Every renderer string that names SwiftShader
// finishes the page, and every one that does not -- Apple, NVIDIA, Intel alike
// -- leaves the whole hardware section as loading placeholders forever. The
// site takes a shortcut when it reads a software renderer and runs its real
// hardware probe otherwise, and it is that probe the engine cannot complete.
//
// Rebuilding the engine per string would make a sweep this wide unaffordable,
// so each variant is a `getParameter` override injected ahead of the page's own
// scripts. That is only trustworthy because `swiftshader` reproduces, to the
// score, what rebuilding with the Linux table produced
// (results/macos-claim-isolation-linux-renderer-strings.json) -- run it in any
// sweep you care about, as the method's own control.
//
// Read `skeletons`, not `score`: the site reports 100% when the hardware card
// never resolved, because a card that never arrived deducts nothing.
//
//   node tools/fingerprint/browserscan-gpu-sweep.mjs control swiftshader both-apple
//   node tools/fingerprint/browserscan-gpu-sweep.mjs --list
import { spawn } from 'node:child_process';
import { Cdp, newPage, sleep, PERSONA_DEVICE_SCALE_FACTOR } from './cdp.mjs';

const LIGHTPANDA = 'zig-out/bin/lightpanda';
const PORT = Number(process.env.SWEEP_PORT ?? 9492);
const SETTLE_MS = Number(process.env.SETTLE_MS ?? 30000);
const GAP_MS = Number(process.env.GAP_MS ?? 4000);

// The engine's own two columns (canvas/gpu.zig), which are what the named
// variants are built out of.
const APPLE_V = 'Google Inc. (Apple)';
const APPLE_R = 'ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)';
const SS_V = 'Google Inc. (Google)';
const SS_R = 'ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)';

const VARIANTS = {
  control: null, // no injection: whatever the build reports
  swiftshader: [SS_V, SS_R],
  'both-apple': [APPLE_V, APPLE_R],

  // Which of the two strings matters: only the renderer does.
  'vendor-only': [APPLE_V, SS_R],
  'renderer-only': [SS_V, APPLE_R],

  // The Apple renderer, taken apart. None of these tokens is the trigger:
  // the Apple-shaped strings fail with no "Apple" in them, and the
  // SwiftShader-shaped ones pass with "Apple", "Metal" or "Unspecified
  // Version" spliced in.
  'r-apple-vendor-tok': [SS_V, 'ANGLE (Apple, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)'],
  'r-metal-no-apple': [SS_V, 'ANGLE (Google, ANGLE Metal Renderer: Generic M4, Unspecified Version)'],
  'r-apple-m4-only': [SS_V, 'ANGLE (Google, Vulkan 1.3.0 (Apple M4), SwiftShader driver)'],
  'r-metal-shape': [SS_V, 'ANGLE (Nvidia, ANGLE Metal Renderer: Nvidia GTX, Unspecified Version)'],
  'r-apple-word': [SS_V, 'ANGLE (Google, Vulkan 1.3.0 (Apple Device (Subzero) (0x0000C0DE)), SwiftShader driver)'],
  'k-metal': [SS_V, 'ANGLE (Google, Vulkan 1.3.0 (Metal Device (Subzero) (0x0000C0DE)), SwiftShader driver)'],
  'k-unspec': [SS_V, 'ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), Unspecified Version)'],
  'k-colon': [SS_V, 'ANGLE (Google, Vulkan 1.3.0: (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)'],
  's-no-inner-paren': [SS_V, 'ANGLE (Google, SwiftShader Device Subzero 0x0000C0DE, SwiftShader driver)'],
  's-metal-inner-paren': [SS_V, 'ANGLE (Google, ANGLE Metal Renderer: Generic M4 (Subzero), Unspecified Version)'],
  'd-angle-twice': [SS_V, 'ANGLE (Google, ANGLE Vulkan 1.3.0 (SwiftShader Device), SwiftShader driver)'],
  'd-angle-twice-plain': [SS_V, 'ANGLE (Google, ANGLE Device, SwiftShader driver)'],
  'd-metal-renderer-noangle': [SS_V, 'ANGLE (Google, Metal Renderer: Generic M4, Unspecified Version)'],
  'd-renderer-colon': [SS_V, 'ANGLE (Google, SwiftShader Renderer: Generic M4, SwiftShader driver)'],
  'm-phrase-only': [SS_V, 'ANGLE (Google, Metal Renderer, SwiftShader driver)'],
  'm-bare': [SS_V, 'Metal Renderer'],
  'm-nospace': [SS_V, 'ANGLE (Google, MetalRenderer: Generic M4, SwiftShader driver)'],
  'm-lowercase': [SS_V, 'ANGLE (Google, metal renderer: Generic M4, SwiftShader driver)'],

  // The rule the whole sweep reduces to, stated as four cells: two real GPUs
  // that have nothing to do with Apple stall, and both Apple and NVIDIA finish
  // the moment the word SwiftShader is appended to them.
  'w-nvidia-d3d': [SS_V, 'ANGLE (NVIDIA, NVIDIA GeForce RTX 3080 Direct3D11 vs_5_0 ps_5_0, D3D11)'],
  'w-intel-gl': [SS_V, 'ANGLE (Intel, Mesa Intel(R) UHD Graphics 620 (KBL GT2), OpenGL 4.6)'],
  'w-apple-plus-ss': [APPLE_V, 'ANGLE (Apple, ANGLE Metal Renderer: Apple M4, SwiftShader)'],
  'w-nvidia-plus-ss': [SS_V, 'ANGLE (NVIDIA, NVIDIA GeForce RTX 3080 Direct3D11 vs_5_0 ps_5_0, SwiftShader)'],
};

const wanted = process.argv.slice(2);
if (!wanted.length || wanted[0] === '--list') {
  console.error('variants:\n  ' + Object.keys(VARIANTS).join('\n  '));
  process.exit(wanted.length ? 0 : 2);
}

const PROBE = `(() => {
  const txt = (el) => (el ? (el.textContent || '').replace(/\\s+/g, ' ').trim() : null);
  const main = document.querySelector('main');
  if (!main) return JSON.stringify({ error: 'no main element' });
  const rows = [...main.querySelectorAll('._11xj7yu')].map((row) => ({
    label: txt(row.querySelector('._to28ap')),
    val: (txt(row.querySelector('._1pu5vjm')) || '').slice(0, 70),
  }));
  const pick = (name) => (rows.find((r) => r.label === name) || {}).val ?? '(no row)';
  return JSON.stringify({
    score: txt([...main.querySelectorAll('._5tuium span')].pop()),
    warnings: [...main.querySelectorAll('ul._16rztjr > li')].map(txt),
    skeletons: document.querySelectorAll('[class*=skeleton]').length,
    rowCount: rows.length,
    blankRows: rows.filter((r) => !r.val).length,
    unmaskedVendor: pick('Unmasked Vendor'),
    unmaskedRenderer: pick('Unmasked Renderer'),
    webgl: pick('WebGL'),
    canvas: pick('Canvas'),
    audio: pick('Audio'),
    mainTotal: main.querySelectorAll('*').length,
  });
})()`;

// One engine process per variant. The engine allows a single browser context at
// a time, and a fresh process is also the cleanest guarantee that nothing from
// the previous load carries over into the next.
async function startEngine(port) {
  const p = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(port)], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  p.stdout.resume();
  p.stderr.resume();
  for (let i = 0; i < 300; i++) {
    try {
      await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
      break;
    } catch {
      await sleep(200);
    }
  }
  return p;
}

const out = [];
let port = PORT;
for (const name of wanted) {
  if (!(name in VARIANTS)) {
    console.error('unknown variant ' + name);
    continue;
  }
  const pair = VARIANTS[name];
  const proc = await startEngine(++port);
  const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
  const { sessionId } = await newPage(cdp);
  await cdp.send('Page.enable', {}, sessionId).catch(() => {});
  await cdp.send('Runtime.enable', {}, sessionId).catch(() => {});
  if (pair) {
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `(() => {
        const V = ${JSON.stringify(pair[0])}, R = ${JSON.stringify(pair[1])};
        for (const n of ['WebGLRenderingContext', 'WebGL2RenderingContext']) {
          const ctor = globalThis[n];
          if (!ctor || !ctor.prototype.getParameter) continue;
          const orig = ctor.prototype.getParameter;
          ctor.prototype.getParameter = function (p) {
            if (p === 37445) return V;
            if (p === 37446) return R;
            return orig.call(this, p);
          };
        }
      })()`,
    }, sessionId);
  }
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1920, height: 1080, deviceScaleFactor: PERSONA_DEVICE_SCALE_FACTOR, mobile: false,
  }, sessionId).catch(() => {});
  const t0 = Date.now();
  await cdp.send('Page.navigate', { url: 'https://www.browserscan.net/' }, sessionId);
  await sleep(SETTLE_MS);
  let r;
  try {
    const res = await cdp.send('Runtime.evaluate', { expression: PROBE, returnByValue: true }, sessionId);
    r = JSON.parse(res.result.value);
  } catch (e) {
    r = { error: String(e.message) };
  }
  out.push({
    variant: name,
    injected: pair ? { vendor: pair[0], renderer: pair[1] } : 'none (engine values)',
    hasSwiftShader: pair ? pair[1].includes('SwiftShader') : null,
    elapsedMs: Date.now() - t0,
    ...r,
  });
  console.error(`[${name}] skeletons=${r.skeletons} score=${r.score} blank=${r.blankRows}/${r.rowCount}`);
  cdp.close();
  proc.kill('SIGKILL');
  await sleep(GAP_MS);
}

console.log(JSON.stringify(out, null, 1));
process.exit(0);
