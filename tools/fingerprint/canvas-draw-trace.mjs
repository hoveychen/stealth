// Which drawing calls produce the widget's pixel readbacks, and which of them
// we answer with zeroes.
//
// `fo-plaintext` already showed *that* the readbacks differ. Four of them go
// through `TextEncoder.encode` in the widget's own realm, and on the arm that
// clears they carry pixels:
//
//     chars   zeroes  arm that clears        this fork
//      9216     1211  a render                9216 zeroes
//      1024        0  solid d78a74 opaque     never happens
//      8624     1725  a render                8624 zeroes
//      4096     3744  black run then clear    never happens
//
// The two that happen come back the right *size* and the wrong *content*, so
// the readback path itself is wired up and it is the drawing underneath that is
// missing -- `raster.zig` rasterises `fillRect`, `clearRect` and `strokeRect`
// and nothing else, and `WebGLRenderingContext.readPixels` writes nothing at
// all. The two that never happen are a different question again: some branch
// upstream of them is not taken here.
//
// None of that says *which* calls to implement. A readback is the end of a
// sequence, and the sequence is what has to be reproduced -- so record it:
// every method and every accessor on the four context prototypes, kept in a
// per-context log, and flushed when a readback happens with the readback's own
// result attached. What comes out is one record per readback saying "these 40
// calls produced these 9216 bytes", which is the thing the arms can be diffed
// on.
//
// Two properties of the instrument are worth stating, because both were chosen
// against an alternative that looked simpler:
//
//   - The prototypes are wrapped, not the instances. An instance-level wrapper
//     would leave `CanvasRenderingContext2D.prototype.fillRect` answering as
//     itself, which reads better -- but the widget hands its context around and
//     a per-instance wrapper has to be re-applied at every entry point that can
//     hand one back (`getContext`, `OffscreenCanvas`, `transferControlToOffscreen`).
//     Missing one silently loses a whole context's log. The prototype is the one
//     place all of them pass through.
//
//   - Accessors are wrapped alongside methods. `fillStyle`, `font` and
//     `globalAlpha` are assignments rather than calls, and a trace with the
//     fills but not the colours cannot be replayed.
//
// Whether the instrument is honest is a measurement, not an argument: run the
// oracle arm with it in and check the challenge still clears. If it does, the
// wrappers did not change what the page decided. (Same contract, and the same
// `disguise` helper, as `fo-plaintext.mjs`.)
//
// usage:
//   node tools/fingerprint/canvas-draw-trace.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--max-ops n] [--inject-worker]
// env: LP_BIN, CHROME
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
const has = (n) => process.argv.includes(n);

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: canvas-draw-trace.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9264' : '9265'));
const OUT = arg('--out', null);
// A context that is drawn into in a loop would otherwise bury the readback it
// leads to. The cap is per context and per flush, and what it dropped is
// counted rather than hidden.
const MAX_OPS = Number(arg('--max-ops', '600'));
const headedUa = has('--headed-ua');
const injectWorker = has('--inject-worker');
const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const MARK = '@@CDT@@';
const CORE = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var MAX_OPS = ${MAX_OPS};
  var log = console.log.bind(console);
  // Taken before anything below can be replaced, and used for every record, so
  // the instrument's own serialising never shows up as page traffic.
  var stringify = JSON.stringify;
  var ctxSeq = 0, recSeq = 0;
  var inside = false;

  // A console argument is not a guaranteed-lossless channel at the size an op
  // log reaches, so anything long goes over in pieces the collector stitches
  // back together. Short records -- the common case -- still go in one line.
  function emit(rec) {
    if (inside) return;
    inside = true;
    try {
      var s = stringify(rec);
      if (s.length <= 6000) { log(MARK + s); }
      else {
        var id = 'c' + (recSeq++);
        for (var off = 0; off < s.length; off += 6000) {
          log(MARK + stringify({ k: 'chunk', id: id, at: off, s: s.slice(off, off + 6000) }));
        }
        log(MARK + stringify({ k: 'chunk.end', id: id, n: s.length }));
      }
    } catch (e) { /* unserialisable */ }
    inside = false;
  }

  function disguise(wrapper, original) {
    var native_ = 'function ' + (original.name || '') + '() { [native code] }';
    try {
      Object.defineProperty(wrapper, 'name', { value: original.name, configurable: true });
      Object.defineProperty(wrapper, 'length', { value: original.length, configurable: true });
      wrapper.toString = function () { return native_; };
      wrapper.toString.toString = function () { return 'function toString() { [native code] }'; };
    } catch (e) { /* frozen */ }
    return wrapper;
  }

  function hex(u, n) {
    var s = '', lim = Math.min(n, u.length);
    for (var i = 0; i < lim; i++) { var b = u[i].toString(16); s += b.length < 2 ? '0' + b : b; }
    return s;
  }

  // Enough of a buffer to say whether two arms drew the same thing without
  // carrying the buffer: how big, how much of it stayed at zero, what the first
  // bytes are, and one number over all of it.
  function summarise(u) {
    var zeros = 0, h = 2166136261;
    for (var i = 0; i < u.length; i++) {
      if (u[i] === 0) zeros++;
      h ^= u[i]; h = (h * 16777619) >>> 0;
    }
    return { n: u.length, zeros: zeros, fnv: h, head: hex(u, 96) };
  }

  function viewOf(v) {
    try {
      if (v instanceof ArrayBuffer) return new Uint8Array(v);
      if (v && v.buffer instanceof ArrayBuffer) {
        return new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength);
      }
    } catch (e) { /* detached */ }
    return null;
  }

  // Arguments are recorded to be read, not replayed byte for byte: numbers keep
  // four decimals, strings that are short enough keep their text, and anything
  // else keeps its shape.
  function argOf(v) {
    try {
      if (v === null) return null;
      var t = typeof v;
      if (t === 'number') return Math.round(v * 10000) / 10000;
      if (t === 'boolean' || t === 'undefined') return v === undefined ? '?' : v;
      // Shader sources arrive here as one long string and are the one argument
      // that has to survive whole: a fragment shader truncated to its first
      // line is not something a rasteriser can be written against. 1024 keeps
      // the widget's longest (413 chars) intact.
      if (t === 'string') return v.length <= 1024 ? v : { s: v.length, v: v.slice(0, 512) };
      var u = viewOf(v);
      if (u) return { buf: u.length, head: hex(u, 24) };
      if (t === 'object' || t === 'function') {
        var name = '?';
        try { name = (v.constructor && v.constructor.name) || Object.prototype.toString.call(v); } catch (e) {}
        // A gradient assigned to fillStyle is only reproducible with its stops,
        // and the stops are added on the gradient rather than on the context --
        // so they are carried here, at the point the gradient is used.
        try { if (v[STOPS]) return { o: name, stops: v[STOPS] }; } catch (e) {}
        return { o: name };
      }
      return String(t);
    } catch (e) { return { o: 'unreadable' }; }
  }

  // Per-context state hangs off the context object itself: a WeakMap would be
  // tidier but the log has to survive being read from inside a wrapper that the
  // page may call with a borrowed receiver.
  var LOG = '__cdt_log_' + Math.floor(1e9 * 0.4213);
  var ID = '__cdt_id_' + Math.floor(1e9 * 0.4213);
  var STOPS = '__cdt_stops_' + Math.floor(1e9 * 0.4213);

  // Every context ever seen, so a log that never reaches a readback can still be
  // drained. The first arms differed exactly there: this fork never fires the
  // WebGL readback the reference does, and with flush-on-readback as the only
  // exit the twenty-four calls leading up to it were collected and then thrown
  // away -- the one arm that needed explaining was the one that reported
  // nothing. Holding contexts alive costs a probe nothing.
  var CTXS = [];

  function stateOf(ctx) {
    if (!ctx || (typeof ctx !== 'object' && typeof ctx !== 'function')) return null;
    try {
      if (!ctx[LOG]) {
        Object.defineProperty(ctx, ID, { value: 'x' + (ctxSeq++), configurable: true });
        Object.defineProperty(ctx, LOG, { value: { ops: [], dropped: 0 }, configurable: true });
        CTXS.push(ctx);
      }
      return ctx[LOG];
    } catch (e) { return null; }
  }

  function note(ctx, op) {
    var st = stateOf(ctx);
    if (!st) return;
    if (st.ops.length >= MAX_OPS) { st.dropped++; return; }
    st.ops.push(op);
  }

  function sizeOf(ctx) {
    try {
      var c = ctx.canvas;
      if (c) return [c.width, c.height];
    } catch (e) {}
    try { return [ctx.drawingBufferWidth, ctx.drawingBufferHeight]; } catch (e) {}
    return null;
  }

  // A readback ends a sequence, so it takes the log with it: what came out is
  // reported next to what produced it, and the next sequence starts empty.
  function flush(ctx, why, m, args, result) {
    var st = stateOf(ctx);
    var ops = st ? st.ops : [];
    var dropped = st ? st.dropped : 0;
    if (st) { st.ops = []; st.dropped = 0; }
    emit({ k: 'readback', why: why, ctx: (ctx && ctx[ID]) || '?', m: m,
           size: sizeOf(ctx), args: args, r: result, dropped: dropped, ops: ops });
  }

  function wrapMethod(proto, key, kind) {
    var d;
    try { d = Object.getOwnPropertyDescriptor(proto, key); } catch (e) { return; }
    if (!d || typeof d.value !== 'function' || !d.writable) return;
    var original = d.value;
    try {
      proto[key] = disguise(function () {
        var args = [];
        try { for (var i = 0; i < arguments.length; i++) args.push(argOf(arguments[i])); } catch (e) {}
        var out = original.apply(this, arguments);
        try {
          if (key === 'getImageData' || key === 'createImageData') {
            var u = out && out.data ? viewOf(out.data) : null;
            flush(this, kind, key, args, u ? summarise(u) : { n: -1 });
          } else if (key === 'readPixels') {
            // The pixels land in the caller's array, so the result is the
            // argument -- read it *after* the call, not before.
            var p = viewOf(arguments[6]);
            flush(this, kind, key, args, p ? summarise(p) : { n: -1 });
          } else if (key === 'toDataURL' || key === 'toBlob') {
            var s = typeof out === 'string' ? out : '';
            flush(this, kind, key, args, { n: s.length, v: s.slice(0, 64) });
          } else {
            note(this, [key].concat(args));
          }
        } catch (e) { /* keep going */ }
        return out;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  function wrapAccessor(proto, key, kind) {
    var d;
    try { d = Object.getOwnPropertyDescriptor(proto, key); } catch (e) { return; }
    if (!d || typeof d.set !== 'function') return;
    var set = d.set, get = d.get;
    try {
      Object.defineProperty(proto, key, {
        configurable: true, enumerable: d.enumerable,
        get: get ? disguise(function () { return get.call(this); }, get) : undefined,
        set: disguise(function (v) { try { note(this, ['=' + key, argOf(v)]); } catch (e) {} return set.call(this, v); }, set),
      });
    } catch (e) { /* non-configurable */ }
  }

  function instrument(ctor, kind) {
    if (typeof ctor !== 'function' || !ctor.prototype) return 0;
    var proto = ctor.prototype, names;
    try { names = Object.getOwnPropertyNames(proto); } catch (e) { return 0; }
    var n = 0;
    for (var i = 0; i < names.length; i++) {
      var key = names[i];
      if (key === 'constructor' || key === 'canvas') continue;
      var d;
      try { d = Object.getOwnPropertyDescriptor(proto, key); } catch (e) { continue; }
      if (!d) continue;
      // A WebGL prototype is mostly numeric enum constants; only the callables
      // and the settables are worth a wrapper.
      if (typeof d.value === 'function') { wrapMethod(proto, key, kind); n++; }
      else if (typeof d.set === 'function') { wrapAccessor(proto, key, kind); n++; }
    }
    return n;
  }

  try {
    var gproto = globalThis.CanvasGradient && globalThis.CanvasGradient.prototype;
    var addStop = gproto && gproto.addColorStop;
    if (typeof addStop === 'function') {
      gproto.addColorStop = disguise(function (off, color) {
        try {
          if (!this[STOPS]) Object.defineProperty(this, STOPS, { value: [], configurable: true });
          this[STOPS].push([Math.round(off * 10000) / 10000, String(color)]);
        } catch (e) { /* frozen */ }
        return addStop.apply(this, arguments);
      }, addStop);
    }
  } catch (e) { /* non-writable */ }

  var wrapped = {};
  wrapped['2d'] = instrument(globalThis.CanvasRenderingContext2D, '2d');
  wrapped['off2d'] = instrument(globalThis.OffscreenCanvasRenderingContext2D, 'off2d');
  wrapped['gl'] = instrument(globalThis.WebGLRenderingContext, 'gl');
  wrapped['gl2'] = instrument(globalThis.WebGL2RenderingContext, 'gl2');
  wrapped['bitmap'] = instrument(globalThis.ImageBitmapRenderingContext, 'bitmap');

  // getContext is the only place a context is born, and whether it came back at
  // all is itself a difference worth recording -- a null here is a branch the
  // page does not take.
  function wrapGetContext(proto, owner) {
    if (!proto) return;
    var original;
    try { original = proto.getContext; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      proto.getContext = disguise(function (kind, attrs) {
        var out = original.apply(this, arguments);
        try {
          var st = out ? stateOf(out) : null;
          emit({ k: 'getContext', owner: owner, kind: String(kind),
                 attrs: attrs ? argOf(attrs) : null,
                 got: out ? ((out.constructor && out.constructor.name) || 'ctx') : null,
                 ctx: out ? out[ID] : null, size: out ? sizeOf(out) : null });
          if (st) { /* logging starts empty */ }
        } catch (e) { /* keep going */ }
        return out;
      }, original);
    } catch (e) { /* non-writable */ }
  }
  wrapGetContext(globalThis.HTMLCanvasElement && globalThis.HTMLCanvasElement.prototype, 'canvas');
  wrapGetContext(globalThis.OffscreenCanvas && globalThis.OffscreenCanvas.prototype, 'offscreen');

  // toDataURL lives on the element, not on the context, and it is a readback of
  // the same pixels by another route.
  try {
    var el = globalThis.HTMLCanvasElement && globalThis.HTMLCanvasElement.prototype;
    if (el) {
      ['toDataURL', 'toBlob'].forEach(function (key) {
        var original = el[key];
        if (typeof original !== 'function') return;
        el[key] = disguise(function () {
          var args = [];
          for (var i = 0; i < arguments.length; i++) args.push(argOf(arguments[i]));
          var out = original.apply(this, arguments);
          try {
            var ctx = null;
            try { ctx = this.__cdt_ctx || null; } catch (e) {}
            var s = typeof out === 'string' ? out : '';
            emit({ k: 'readback', why: 'element', m: key, ctx: '-',
                   size: [this.width, this.height], args: args,
                   r: { n: s.length, v: s.slice(0, 64) }, dropped: 0, ops: [] });
          } catch (e) {}
          return out;
        }, original);
      });
    }
  } catch (e) { /* non-writable */ }

  // Anything still sitting in a log after the drawing has gone quiet is a
  // sequence that led nowhere, which is the interesting kind.
  try {
    setInterval(function () {
      for (var i = 0; i < CTXS.length; i++) {
        var ctx = CTXS[i], st = ctx[LOG];
        if (!st || !st.ops.length) continue;
        var ops = st.ops, dropped = st.dropped;
        st.ops = []; st.dropped = 0;
        emit({ k: 'drain', ctx: ctx[ID], size: sizeOf(ctx), dropped: dropped, ops: ops });
      }
    }, 2500);
  } catch (e) { /* no timers here */ }

  emit({ k: 'installed',
         href: String((globalThis.location || {}).href || '?').slice(0, 200),
         worker: typeof globalThis.WorkerGlobalScope !== 'undefined',
         wrapped: wrapped,
         has: { canvas: typeof globalThis.HTMLCanvasElement,
                offscreen: typeof globalThis.OffscreenCanvas,
                gl: typeof globalThis.WebGLRenderingContext,
                gl2: typeof globalThis.WebGL2RenderingContext } });
})();`;

// The document-realm half, verbatim in shape from fo-plaintext.mjs: the only
// realm that can be armed before its own code runs is also the one where the
// worker is built, so this is where the recorder can be put in front of a
// worker's source text. OffscreenCanvas is a worker-reachable surface, so the
// option is kept even though the readbacks this chases are in the document.
const WORKER_HOOK = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var INJECT = ${injectWorker ? 'true' : 'false'};
  var PAYLOAD = ${JSON.stringify(CORE)};
  var log = console.log.bind(console);
  var stringify = JSON.stringify;
  function emit(rec) { try { log(MARK + stringify(rec)); } catch (e) { /* unserialisable */ } }

  function textOf(parts) {
    if (!parts || typeof parts.length !== 'number') return null;
    var out = '';
    for (var i = 0; i < parts.length; i++) {
      if (typeof parts[i] !== 'string') return null;
      out += parts[i];
    }
    return out;
  }

  try {
    var OrigBlob = globalThis.Blob;
    if (typeof OrigBlob === 'function' && INJECT) {
      globalThis.Blob = new Proxy(OrigBlob, {
        construct: function (target, args) {
          var src = null;
          try { src = textOf(args[0]); } catch (e) { /* exotic parts */ }
          if (src !== null) {
            emit({ k: 'worker.blob', n: src.length });
            try { args = [[PAYLOAD + '\\n' + src], args[1]]; } catch (e) { /* leave it */ }
          }
          return new target(args[0], args[1]);
        },
      });
    }
  } catch (e) { /* non-writable */ }
})();`;

const RECORDER = `${WORKER_HOOK}\n${CORE}`;

async function headedUserAgent() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${PORT + 1}`,
        `--user-data-dir=${dir}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${PORT + 1}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent for --headed-ua');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE, maxOps: MAX_OPS, injectWorker,
    userAgentOverride: null,
    contexts: [],    // every getContext, and what it answered with
    readbacks: [],   // one per pixel readback, with the ops that produced it
    drains: [],      // calls that never reached a readback
    realms: [],
    installs: [],    // which realms the recorder reached, and what it found there
    console: [],
    exceptions: [],
};

if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    state.userAgentOverride = await headedUserAgent();
    console.log(`--headed-ua: ${state.userAgentOverride}`);
}

let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-cdt-'))}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--window-size=1920,1080',
        '--headless=new',
        ...(state.userAgentOverride ? [`--user-agent=${state.userAgentOverride}`] : []),
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info')], { stdio: ['ignore', 'pipe', 'pipe'] });

const engineLog = [];
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));

const chunks = new Map();

let cdp = null;
try {
    for (let i = 0; i < 100; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) { state.version = await r.json(); break; }
        } catch { /* not up */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId: pageSession } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // Same arming as fo-plaintext: the widget is an out-of-process frame under
    // Chrome's site isolation, so its target has to be caught paused on start
    // for the script to land ahead of its first statement. Workers are resumed
    // before anything else is sent to them -- a paused worker's queue is blocked
    // head-on by whatever is sent ahead of the resume.
    async function arm(sid, why, type) {
        const rec = { session: sid ?? 'page', why, type, installed: false, resumed: false };
        state.realms.push(rec);
        if (type && /worker/.test(type)) {
            rec.worker = true;
            await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
                .then(() => { rec.resumed = true; }).catch(() => { });
            return;
        }
        await cdp.send('Runtime.enable', undefined, sid).catch(() => { });
        await cdp.send('Page.enable', undefined, sid).catch(() => { });
        try {
            await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: RECORDER }, sid);
            rec.installed = true;
        } catch (err) { rec.err = String(err.message ?? err); }
        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid).catch(() => { });
        await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
            .then(() => { rec.resumed = true; }).catch(() => { });
    }

    function take(session, rec) {
        if (rec.k === 'installed') state.installs.push({ session, ...rec });
        else if (rec.k === 'getContext') state.contexts.push({ session, ...rec });
        else if (rec.k === 'readback') state.readbacks.push({ session, ...rec });
        else if (rec.k === 'drain') state.drains.push({ session, ...rec });
        else if (rec.k === 'worker.blob') state.installs.push({ session, ...rec });
    }

    cdp.on((msg) => {
        const p = msg.params ?? {};
        if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
            arm(p.sessionId, p.targetInfo?.url ?? '?', p.targetInfo?.type ?? '?').catch(() => { });
            return;
        }
        if (msg.method === 'Runtime.consoleAPICalled') {
            const text = (p.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ');
            const session = msg.sessionId ?? 'page';
            if (text.startsWith(MARK)) {
                let rec;
                try { rec = JSON.parse(text.slice(MARK.length)); } catch { /* truncated */ }
                if (!rec) return;
                if (rec.k === 'chunk') {
                    chunks.set(rec.id, (chunks.get(rec.id) ?? '') + rec.s);
                } else if (rec.k === 'chunk.end') {
                    const s = chunks.get(rec.id) ?? '';
                    chunks.delete(rec.id);
                    if (s.length !== rec.n) return;
                    try { take(session, JSON.parse(s)); } catch { /* lost a piece */ }
                } else {
                    take(session, rec);
                }
            } else if (state.console.length < 200) {
                state.console.push(`${p.type}: ${text.slice(0, 200)}`);
            }
            return;
        }
        if (msg.method === 'Runtime.exceptionThrown' && state.exceptions.length < 60) {
            state.exceptions.push((p.exceptionDetails?.exception?.description
                ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 200));
        }
    });

    await arm(pageSession, 'page', 'page');
    await cdp.send('Page.navigate', { url: URL_ }, pageSession);
    await sleep(SETTLE);

    try {
        state.final = await cdp.send('Runtime.evaluate', {
            expression: `JSON.stringify({
                title: document.title,
                nodes: document.querySelectorAll('*').length,
                text: (document.body ? document.body.innerText : '').slice(0, 120),
            })`,
            returnByValue: true,
        }, pageSession).then((r) => JSON.parse(r.result?.value ?? 'null'));
    } catch (err) { state.final = { err: String(err.message ?? err) }; }
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}
state.engineLog = engineLog.join('').slice(-4000);

// --- report ---------------------------------------------------------------
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''}${injectWorker ? ' --inject-worker' : ''} ===`);
console.log(`realms armed: ${state.realms.filter((r) => r.installed).length}/${state.realms.length}`);
for (const i of state.installs.filter((i) => i.k === 'installed')) {
    const w = i.wrapped ?? {};
    console.log(`  installed ${String(i.href).slice(0, 62).padEnd(62)}`
        + ` 2d=${w['2d']} off2d=${w.off2d} gl=${w.gl} gl2=${w.gl2}`);
}
console.log(`contexts: ${state.contexts.length}`);
for (const c of state.contexts) {
    console.log(`  getContext(${JSON.stringify(c.kind)}) on ${c.owner}`
        + ` -> ${c.got === null ? 'NULL' : c.got}`
        + ` ${c.size ? `${c.size[0]}x${c.size[1]}` : ''}`
        + ` attrs=${JSON.stringify(c.attrs)}`);
}
console.log(`readbacks: ${state.readbacks.length}`);
for (const r of state.readbacks) {
    const size = r.size ? `${r.size[0]}x${r.size[1]}` : '?';
    console.log(`  ${r.m.padEnd(13)} ${r.why.padEnd(6)} ${String(r.ctx).padEnd(4)} ${size.padStart(9)}`
        + ` n=${String(r.r?.n ?? -1).padStart(7)} zeros=${String(r.r?.zeros ?? '-').padStart(7)}`
        + ` fnv=${r.r?.fnv ?? '-'} ops=${r.ops.length}${r.dropped ? `+${r.dropped}dropped` : ''}`);
    console.log(`      head=${(r.r?.head ?? r.r?.v ?? '').slice(0, 64)}`);
    for (const op of r.ops) console.log(`      . ${JSON.stringify(op)}`);
}
console.log(`drains (calls that reached no readback): ${state.drains.length}`);
for (const d of state.drains) {
    const size = d.size ? `${d.size[0]}x${d.size[1]}` : '?';
    console.log(`  ${String(d.ctx).padEnd(4)} ${size.padStart(9)} ops=${d.ops.length}${d.dropped ? `+${d.dropped}dropped` : ''}`);
    for (const op of d.ops) console.log(`      . ${JSON.stringify(op)}`);
}
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.error) console.log(`ERROR ${state.error}`);

if (OUT) {
    const out = path.resolve(REPO, OUT.startsWith('tools/') ? OUT : path.join('tools/fingerprint', OUT));
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.writeFile(out, JSON.stringify(state, null, 1));
    console.log(`wrote ${out}`);
}
