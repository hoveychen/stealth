// Why a page stops halfway, when nothing throws.
//
// A script injected ahead of the page's own wraps every async surface a
// fingerprint pipeline can sit on -- fetch, canvas, WebGL, WebGPU, audio,
// FileReader, Blob, image loads, timers -- and records when each call starts
// and whether it ever finishes. Explicitly constructed promises are recorded
// with the stack that made them, so a promise left pending names the site
// function holding the pipeline open. (Native async/await goes through the
// intrinsic and stays invisible; the pattern that hangs is nearly always a
// promise wrapped around a callback API, which does not.)
//
// Run the same page three ways and subtract: the engine in the state that
// stalls, the engine in a state that does not, and the real Chrome. Whatever is
// pending in the first and settled in the other two is the bug. That is how the
// browserscan hardware card was traced to FileReader dispatching its load event
// synchronously -- the site registers that listener on the line after the read.
//
//   node tools/fingerprint/stall-trace.mjs stall           # engine, Apple GPU strings
//   node tools/fingerprint/stall-trace.mjs ok              # engine, SwiftShader strings
//   node tools/fingerprint/stall-trace.mjs native --chrome # the real Chrome
//
// URL points it at another page and PROBE at that page's own read of whether it
// finished, so the same subtraction works anywhere:
//
//   URL=https://iphey.com/ PROBE='document.body.innerText.match(/Looks\s+(\w+)/)' \
//     LP_BIN=/abs/path/zig-out/bin/lightpanda node tools/fingerprint/stall-trace.mjs stall
//
// The wrappers are not free of side effects: anything constructed rather than
// called (RTCPeerConnection) breaks if wrapped this way, so check that the
// run's own outcome still matches an untraced one before trusting a trace.
import { spawn } from 'node:child_process';
import { Cdp, newPage, sleep, PERSONA_DEVICE_SCALE_FACTOR } from './cdp.mjs';

const SETTLE_MS = Number(process.env.SETTLE_MS ?? 30000);
const PAGE_URL = process.env.URL ?? 'https://www.browserscan.net/';
const PROBE = process.env.PROBE ?? 'document.querySelectorAll("[class*=skeleton]").length';
const LP_BIN = process.env.LP_BIN ?? 'zig-out/bin/lightpanda';
const APPLE_V = 'Google Inc. (Apple)';
const APPLE_R = 'ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)';
const SS_V = 'Google Inc. (Google)';
const SS_R = 'ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)';

const VARIANTS = { stall: [APPLE_V, APPLE_R], ok: [SS_V, SS_R], native: null };

const TRACE = (pair) => `(() => {
  const T0 = Date.now();
  const log = [];
  const now = () => Date.now() - T0;
  const rec = (kind, detail) => { const e = { t: now(), kind, detail, done: null }; log.push(e); return e; };
  const describe = (v) => {
    if (v === null || v === undefined) return String(v);
    if (typeof v !== 'object') return typeof v + ':' + String(v).slice(0, 40);
    const c = v.constructor && v.constructor.name;
    if (typeof Blob !== 'undefined' && v instanceof Blob) return 'Blob(' + v.size + ',' + v.type + ')';
    if (v.byteLength !== undefined) return c + '(' + v.byteLength + ')';
    if (v.width !== undefined && v.height !== undefined) return c + '(' + v.width + 'x' + v.height + ')';
    return String(c);
  };
  const settle = (e, how) => { if (e.done === null) e.done = { t: now(), how: String(how).slice(0, 120) }; };
  const track = (e, p) => {
    try { p.then((v) => { settle(e, 'resolved ' + describe(v)); return v; }, (err) => { settle(e, 'rejected: ' + (err && err.message)); }); } catch { settle(e, 'not-thenable'); }
    return p;
  };
  window.__trace = log;
  window.__errs = [];
  addEventListener('error', (ev) => window.__errs.push('error: ' + (ev.message || ev.error) + ' @' + ev.filename + ':' + ev.lineno + ' ' + ((ev.error && ev.error.stack) || '').slice(0, 300)));
  addEventListener('unhandledrejection', (ev) => window.__errs.push('rejection: ' + (ev.reason && (ev.reason.message || ev.reason)) + ' ' + ((ev.reason && ev.reason.stack) || '').slice(0, 300)));

  // Every explicitly constructed promise, with the stack that made it. Native
  // async/await goes through the intrinsic and is invisible here, but a probe
  // that wraps a callback API -- which is what a stall usually is -- does not.
  const NativePromise = window.Promise;
  const promises = [];
  window.__promises = promises;
  class TracedPromise extends NativePromise {
    constructor(executor) {
      let e = null;
      try { e = { t: now(), stack: String(new Error().stack || '').split('\\n').slice(1, 5).join(' <- '), done: null }; promises.push(e); } catch { /* ignore */ }
      super((res, rej) => executor(
        (v) => { if (e && e.done === null) e.done = { t: now(), how: 'resolved' }; res(v); },
        (err) => { if (e && e.done === null) e.done = { t: now(), how: 'rejected: ' + (err && err.message) }; rej(err); },
      ));
    }
  }
  window.Promise = TracedPromise;

  // the strings under test (omitted entirely for the native variant)
  const OVERRIDE = ${JSON.stringify(pair)};
  if (OVERRIDE) for (const n of ['WebGLRenderingContext', 'WebGL2RenderingContext']) {
    const ctor = globalThis[n];
    if (!ctor || !ctor.prototype.getParameter) continue;
    const orig = ctor.prototype.getParameter;
    ctor.prototype.getParameter = function (p) {
      if (p === 37445) return OVERRIDE[0];
      if (p === 37446) return OVERRIDE[1];
      return orig.call(this, p);
    };
  }

  const wrapSync = (obj, name, label) => {
    if (!obj || typeof obj[name] !== 'function') { rec('missing', label + '.' + name); return; }
    const orig = obj[name];
    obj[name] = function (...a) {
      const e = rec('call', label + '.' + name + ' ' + JSON.stringify(a.slice(0, 2)).slice(0, 100));
      try {
        const r = orig.apply(this, a);
        if (r && typeof r.then === 'function') track(e, r); else settle(e, 'sync ' + describe(r));
        return r;
      } catch (err) { settle(e, 'threw: ' + err.message); throw err; }
    };
  };

  wrapSync(window, 'fetch', 'window');
  wrapSync(XMLHttpRequest.prototype, 'send', 'xhr');
  wrapSync(XMLHttpRequest.prototype, 'open', 'xhr');
  wrapSync(window, 'createImageBitmap', 'window');
  wrapSync(HTMLCanvasElement.prototype, 'getContext', 'canvas');
  wrapSync(HTMLCanvasElement.prototype, 'toDataURL', 'canvas');
  wrapSync(HTMLCanvasElement.prototype, 'toBlob', 'canvas');
  wrapSync(WebGLRenderingContext.prototype, 'getExtension', 'gl');
  wrapSync(WebGLRenderingContext.prototype, 'readPixels', 'gl');
  wrapSync(WebGLRenderingContext.prototype, 'getSupportedExtensions', 'gl');
  wrapSync(WebGLRenderingContext.prototype, 'getShaderPrecisionFormat', 'gl');
  if (window.OffscreenCanvas) wrapSync(OffscreenCanvas.prototype, 'getContext', 'offscreen');
  if (window.OffscreenCanvas) wrapSync(OffscreenCanvas.prototype, 'convertToBlob', 'offscreen');
  if (window.OfflineAudioContext) wrapSync(OfflineAudioContext.prototype, 'startRendering', 'offlineaudio');
  if (navigator.gpu) { wrapSync(navigator.gpu, 'requestAdapter', 'gpu'); }
  else rec('missing', 'navigator.gpu');
  if (navigator.mediaDevices) wrapSync(navigator.mediaDevices, 'enumerateDevices', 'mediaDevices');
  if (navigator.permissions) wrapSync(navigator.permissions, 'query', 'permissions');
  if (navigator.storage) wrapSync(navigator.storage, 'estimate', 'storage');
  if (window.Worker) {
    const OrigWorker = window.Worker;
    window.Worker = function (...a) {
      rec('call', 'new Worker ' + String(a[0]).slice(0, 80));
      return new OrigWorker(...a);
    };
    window.Worker.prototype = OrigWorker.prototype;
  } else rec('missing', 'Worker');
  if (document.fonts) {
    const e = rec('call', 'document.fonts.ready');
    try { track(e, document.fonts.ready); } catch (err) { settle(e, 'threw: ' + err.message); }
  } else rec('missing', 'document.fonts');
  if (window.speechSynthesis) wrapSync(window.speechSynthesis, 'getVoices', 'speechSynthesis');

  // the blob-consumption path the stall run enters and the ok run does not
  if (window.Blob) {
    wrapSync(Blob.prototype, 'arrayBuffer', 'blob');
    wrapSync(Blob.prototype, 'text', 'blob');
    wrapSync(Blob.prototype, 'slice', 'blob');
    if (Blob.prototype.stream) wrapSync(Blob.prototype, 'stream', 'blob');
  }
  if (window.URL) { wrapSync(URL, 'createObjectURL', 'URL'); wrapSync(URL, 'revokeObjectURL', 'URL'); }
  if (window.FileReader) {
    for (const m of ['readAsDataURL', 'readAsArrayBuffer', 'readAsText', 'readAsBinaryString']) {
      if (typeof FileReader.prototype[m] !== 'function') { rec('missing', 'FileReader.' + m); continue; }
      const orig = FileReader.prototype[m];
      FileReader.prototype[m] = function (...a) {
        const e = rec('call', 'FileReader.' + m);
        this.addEventListener('load', () => settle(e, 'load event'));
        this.addEventListener('error', () => settle(e, 'error event'));
        this.addEventListener('loadend', () => settle(e, 'loadend event'));
        return orig.apply(this, a);
      };
    }
  } else rec('missing', 'FileReader');
  if (window.HTMLImageElement) {
    if (HTMLImageElement.prototype.decode) wrapSync(HTMLImageElement.prototype, 'decode', 'img');
    const d = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (d && d.set) {
      Object.defineProperty(HTMLImageElement.prototype, 'src', {
        configurable: true, enumerable: d.enumerable, get: d.get,
        set(v) {
          const e = rec('call', 'img.src=' + String(v).slice(0, 60));
          this.addEventListener('load', () => settle(e, 'load event'));
          this.addEventListener('error', () => settle(e, 'error event'));
          return d.set.call(this, v);
        },
      });
    } else rec('missing', 'HTMLImageElement.src setter');
  }
  if (window.Response) wrapSync(Response.prototype, 'blob', 'response');

  // the rest of the async surface a fingerprint pipeline can sit on
  if (window.crypto && window.crypto.subtle) {
    wrapSync(crypto.subtle, 'digest', 'subtle');
    wrapSync(crypto.subtle, 'importKey', 'subtle');
  } else rec('missing', 'crypto.subtle');
  if (window.indexedDB) wrapSync(indexedDB, 'open', 'indexedDB'); else rec('missing', 'indexedDB');
  if (navigator.getBattery) wrapSync(navigator, 'getBattery', 'navigator'); else rec('missing', 'navigator.getBattery');
  if (window.caches) wrapSync(caches, 'open', 'caches'); else rec('missing', 'caches');
  if (document.hasStorageAccess) wrapSync(document, 'hasStorageAccess', 'document');
  if (navigator.locks) wrapSync(navigator.locks, 'request', 'locks');
  if (window.Notification && Notification.requestPermission) wrapSync(Notification, 'requestPermission', 'Notification');
  if (document.fonts) { wrapSync(document.fonts, 'load', 'fonts'); wrapSync(document.fonts, 'check', 'fonts'); }
  if (navigator.serviceWorker) {
    const e = rec('call', 'serviceWorker.ready');
    try { track(e, navigator.serviceWorker.ready); } catch (err) { settle(e, 'threw: ' + err.message); }
  } else rec('missing', 'navigator.serviceWorker');
  if (window.requestIdleCallback) {
    const orig = window.requestIdleCallback;
    window.requestIdleCallback = function (cb, ...a) {
      const e = rec('call', 'requestIdleCallback');
      return orig.call(this, (...x) => { settle(e, 'fired'); return cb(...x); }, ...a);
    };
  } else rec('missing', 'requestIdleCallback');
  {
    const orig = window.setTimeout;
    window.setTimeout = function (cb, ms, ...a) {
      if (!(ms >= 500) || typeof cb !== 'function') return orig.call(this, cb, ms, ...a);
      const e = rec('call', 'setTimeout ' + ms + 'ms');
      return orig.call(this, (...x) => { settle(e, 'fired'); return cb(...x); }, ms, ...a);
    };
  }

  // frame pump: if the probe drives rAF, a stall shows as the count freezing
  let frames = 0;
  const tick = () => { frames++; requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
  window.__frames = () => frames;
})()`;

const which = process.argv[2] ?? 'stall';
const useChrome = process.argv.includes('--chrome');
const pair = VARIANTS[which];
const port = Number(process.env.PORT ?? 9520);

let proc;
if (useChrome) {
  const os = await import('node:os');
  const fsp = await import('node:fs/promises');
  const path = await import('node:path');
  const profile = await fsp.mkdtemp(path.join(os.tmpdir(), 'fp-trace-'));
  proc = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
  proc = spawn(LP_BIN,
    ['serve', '--host', '127.0.0.1', '--port', String(port)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 300; i++) {
  try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
}
const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
let sessionId;
if (useChrome) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
} else {
  ({ sessionId } = await newPage(cdp));
}
await cdp.send('Page.enable', {}, sessionId).catch(() => {});
await cdp.send('Runtime.enable', {}, sessionId).catch(() => {});
await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: TRACE(pair) }, sessionId);
await cdp.send('Emulation.setDeviceMetricsOverride',
  { width: 1920, height: 1080, deviceScaleFactor: PERSONA_DEVICE_SCALE_FACTOR, mobile: false }, sessionId).catch(() => {});
await cdp.send('Page.navigate', { url: PAGE_URL }, sessionId);
await sleep(SETTLE_MS);

const READ = `JSON.stringify({
  trace: (window.__trace || []).map((e) => ({ t: e.t, kind: e.kind, detail: e.detail, done: e.done })),
  errs: window.__errs || [],
  frames: typeof window.__frames === 'function' ? window.__frames() : null,
  promises: (window.__promises || []).filter((p) => p.done === null).map((p) => ({ t: p.t, stack: p.stack })),
  promiseTotal: (window.__promises || []).length,
  probe: (() => { try { return ${JSON.stringify(PROBE)} && eval(${JSON.stringify(PROBE)}); } catch (e) { return 'probe threw: ' + e.message; } })(),
})`;
const res = await cdp.send('Runtime.evaluate', { expression: READ, returnByValue: true }, sessionId);
console.log(JSON.stringify({ variant: which, ...JSON.parse(res.result.value) }, null, 1));
cdp.close();
proc.kill('SIGKILL');
process.exit(0);
