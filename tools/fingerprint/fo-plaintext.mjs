// What does the widget's first `fo/` POST actually say, before it is encrypted?
//
// E1 put the first divergence at the widget's *first* telemetry POST: 4 716
// bytes on an arm that clears, 4 855/4 866 here, and non-deterministic where the
// reference is fixed (README, "Round 3 is not where the payload first differs").
// The body on the wire is one ciphertext under a per-session key, so the diff
// has to happen upstream of the encryption.
//
// Two routes were tried first and are worth recording as closed:
//
//   - Splitting the ciphertext on `$` and comparing field counts. `$` is a
//     character in the encoding alphabet, not a separator; the counts are noise.
//   - Replaying the captured widget document offline under `vm-trace`. Served
//     framed from a second origin the document loads, installs nothing, and
//     never attempts its first POST -- the parent hands it its challenge
//     parameters over `postMessage` and the replay's host page does not, so the
//     assembly this wants to watch never starts. (`--kick runProgram` cannot
//     substitute: round 1 is assembled by the document's own code, and
//     `runProgram` is for the *program* that arrives in round 1's reply.)
//
// So instrument the funnels the plaintext must pass through on its way out, live
// on the real station, in the widget's own realm:
//
//   crypto.subtle.encrypt / digest   the data argument is the plaintext
//   TextEncoder.prototype.encode     the usual step just before it
//   JSON.stringify                   how a collected object becomes a string
//   btoa                            the usual step just after it
//
// Every wrapper forwards to the original and returns its value unchanged, and
// each one's `toString` is made to answer with the native source text, so a
// program that checks is told what it would have been told anyway. Whether the
// instrument is honest is not an argument to have -- it is a measurement: run
// the oracle arm with the wrappers in and check it still clears. If it does, the
// wrappers did not change what the page decided.
//
// The widget lives in a cross-origin child realm a main-frame evaluate cannot
// reach, so records come back over the console (same reason vm-trace does it)
// and are collected from every session, not just the page's.
//
// The document realm turned out not to be where the payload is built -- no
// fetch, no XHR, no WebCrypto, nothing over 172 bytes through `JSON.stringify`,
// and the POSTs went out anyway. It happens in blob-URL workers, and a worker
// has no Page domain to install a document script into. Reaching in through the
// auto-attach pause instead stalled the challenge three times, which read as
// detection until the records were checked: those runs carried *no* records from
// the worker session, not even the recorder's own `installed` line, and their
// `runIfWaitingForDebugger` never came back. A `Runtime.evaluate` sent to a
// target paused on start blocks that session's inspector queue head-on, so the
// resume behind it never arrives and the worker never reaches its first
// statement. `worker-arm-probe.mjs` reproduces exactly that against a local page
// with no Cloudflare in it, and finds the shape that works: don't involve the
// debugger at all. Wrap `Blob` in the document realm -- which *can* be armed
// before its own code -- and prepend the recorder to the worker's source text.
// That lands ahead of the worker's first statement, where the pause-and-evaluate
// route lands after its first fetch.
//
// usage:
//   node tools/fingerprint/fo-plaintext.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--min n] [--max-records n] [--inject-worker]
//        [--r2] [--r2-min n] [--r2-budget n] [--webgpu]
// env: LP_BIN, CHROME
//
// The launch/arm/collect machinery lives in fo-harness.mjs; what is here is the
// recorder and the report.
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: fo-plaintext.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9262' : '9263'));
const OUT = arg('--out', null);
// Below this the record is a length only. charCodeAt-sized traffic would bury
// the payload, and the payload is thousands of bytes.
const MIN = Number(arg('--min', '400'));
const MAX_RECORDS = Number(arg('--max-records', '400'));
const headedUa = has('--headed-ua');
// Capturing a worker's source text only reads it; prepending the recorder to it
// changes what the worker runs. Two separate questions, so two separate runs.
const injectWorker = has('--inject-worker');
// `--r2` adds the three hooks that stand between the plaintext of round 2 and
// the wire. The funnels above never see it: r2's body is assembled in the
// widget's own realm without a stringify, an encode or a btoa anywhere in it
// (P1 of `cf-r2-185-bytes`), so the only places left to stand are the ones the
// assembly itself uses -- join("") over the characters of the ciphertext, and
// `charCodeAt`/`charAt` whose *receiver* is whatever was cut into them.
//
// Off by default because the last two are hot: they fire per character, and a
// recorder that hashes on every call is quadratic in the body length and the
// challenge never finishes a round. The dedup key here is length plus the first
// and last code unit, read through an unhooked charCodeAt, and nothing shorter
// than R2_MIN is looked at twice.
//
// Alongside those, five cold instruments that answer the next question an input
// that differs raises -- where did it come from? A string the page assembled is
// a cause; one the server handed it is the shape of a decision already taken.
// So: `document.cookie` snapshots, the `responseText`/`response` getters, the
// resolved text of a `Response`, `message` events from the parent, and both
// sides of `JSON.parse`. None of them is hot.
//
// This is the console channel, not the wire one. `report-r2-body --beacon` in
// cf-knobs.mjs asked the same question through a few dozen requests into the
// widget's origin and pushed r2 from 4898 bytes to 21751 -- the instrument, not
// the station. The same hooks with the wire off left r2 at 4898, so the hooks
// are free and only the traffic was not.
const r2 = has('--r2');
// The WebGPU walk (B128 put the 4096-byte buffer on that collector).
const webgpu = has('--webgpu');
const R2_MIN = Number(arg('--r2-min', '2000'));
const R2_BUDGET = Number(arg('--r2-budget', '40'));
// The recorder. Runs before the document's own code in every realm it is
// installed in. `MARK` prefixes each console line so the collector can tell its
// own records from the page's chatter.
const MARK = '@@FOPT@@';
const CORE = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var MIN = ${MIN};
  var n = 0;
  var log = console.log.bind(console);
  var origToString = Function.prototype.toString;
  // Recording a record is itself a JSON.stringify and a console.log, so without
  // this the stringify wrapper feeds itself and the whole record budget goes on
  // the instrument watching itself -- which is what the 4 187 JSON.stringify
  // calls in the first worker-era runs were.
  var inside = false;

  function emit(rec) {
    if (inside || n++ > ${MAX_RECORDS}) return;
    inside = true;
    try { log(MARK + JSON.stringify(rec)); } catch (e) { /* unserialisable */ }
    inside = false;
  }

  // describe() stringifies too, so it has to run inside the guard rather than
  // as an argument evaluated ahead of it.
  function record(label, value, extra, stack) {
    if (inside || n++ > ${MAX_RECORDS}) return;
    inside = true;
    try {
      var rec = { k: label, a: describe(value) };
      if (extra) rec.url = extra;
      if (stack) rec.stack = stack;
      log(MARK + JSON.stringify(rec));
    } catch (e) { /* unserialisable */ }
    inside = false;
  }

  // A wrapper that answers toString() with the native text is a wrapper the
  // page cannot tell from the function it replaced by reading it.
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

  function describe(v) {
    try {
      if (typeof v === 'string') return { t: 'str', n: v.length, v: v.length >= MIN ? v : undefined };
      if (v instanceof ArrayBuffer) return { t: 'ab', n: v.byteLength,
        v: v.byteLength >= MIN ? String.fromCharCode.apply(null, new Uint8Array(v)) : undefined };
      if (v && v.buffer instanceof ArrayBuffer) {
        var u = new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength);
        var s;
        if (u.length >= MIN) { s = ''; for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); }
        return { t: 'view', n: u.length, v: s };
      }
      if (v && typeof v === 'object') {
        var j = JSON.stringify(v);
        return { t: 'obj', n: j ? j.length : -1, v: j && j.length >= MIN ? j : undefined };
      }
      return { t: typeof v, n: -1 };
    } catch (e) { return { t: 'unreadable', n: -1 }; }
  }

  // The last parameter asks for a call stack alongside the value. It is off by
  // default because the cheap funnels (stringify, btoa) fire thousands of
  // times, and on for the encodes: knowing that one of the fifteen is 9216
  // bytes says nothing about which surface produced it, and the stack is the
  // only thing in the realm that still knows.
  // (No backticks in here -- this whole block is inside a template literal.)
  function wrapMethod(owner, key, label, argIndex, stacks) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        var st;
        if (stacks) {
          // V8 caps a stack at 10 frames, and the guard reaches these funnels
          // from inside its own bytecode interpreter -- so the default cuts the
          // chain off in the middle of the VM's re-entrant pq/run/pd cycle and
          // never reaches the frame that names the surface. Raise it for the
          // duration of the capture only and put it back, so a program that
          // reads the property afterwards is told what it would have been told.
          var lim;
          try { lim = Error.stackTraceLimit; Error.stackTraceLimit = 200; } catch (e) { /* frozen */ }
          try { st = String(new Error().stack || '').slice(0, 60000); } catch (e) { /* no stack */ }
          try { Error.stackTraceLimit = lim; } catch (e) { /* frozen */ }
        }
        try { record(label, arguments[argIndex], undefined, st); } catch (e) { /* keep going */ }
        if (label === 'xhr.send') {
          try {
            var b = arguments[0];
            surfaceCensus(typeof b === 'string' ? b.length : (b && b.byteLength) || 0);
          } catch (e) { /* keep going */ }
        }
        // A bare call to a *global* function (btoa, fetch) passes this ===
        // undefined, and forwarding that to the original raises "Illegal
        // invocation" -- which in a worker means the telemetry POST never goes
        // out and the challenge stalls at round 1. Measured, not guessed.
        return original.apply(this === undefined ? globalThis : this, arguments);
      }, original);
    } catch (e) { /* non-writable */ }
  }

  // The plaintext is the third argument to encrypt/sign and the second to
  // digest; everything else here is a funnel it may pass through on the way.
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'encrypt', 'subtle.encrypt', 2); } catch (e) {}
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'sign', 'subtle.sign', 2); } catch (e) {}
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'digest', 'subtle.digest', 1, true); } catch (e) {}
  try { wrapMethod(globalThis.TextEncoder && globalThis.TextEncoder.prototype, 'encode', 'TextEncoder.encode', 0, true); } catch (e) {}
  try { wrapMethod(globalThis.JSON, 'stringify', 'JSON.stringify', 0); } catch (e) {}
  try { wrapMethod(globalThis, 'btoa', 'btoa', 0); } catch (e) {}

  // r3's length is not a function of the encoder inputs: the sum of the 15
  // TextEncoder.encode lengths is a constant per arm (124941 on Chrome, 124920
  // here -- 21 bytes apart), while r3 itself swings 3KB run to run and sits
  // ~2.3KB lower on this engine. Each of those encodes is paired with a
  // subtle.digest of the same length, so the big buffers are HASHED, not sent;
  // whatever fills r3's 88KB comes from somewhere the funnels above cannot see.
  //
  // The two surfaces Cloudflare is known to walk are the realm's own globals
  // and the resource-timing entry names (README: cf judges the total characters
  // of the entry names). Both are countable without copying any of them, and
  // counting is the point: a recorder that emitted the text would put it back
  // into the realm and change the very payload being measured -- measured, the
  // r2 hooks did exactly that and inverted the sign of the difference. So this
  // emits numbers only, once per realm, at the moment a body big enough to be
  // r3 goes out.
  // --- provenance: who PRODUCES what the encodes carry ---------------------
  //
  // The stacks say the guard reaches every encode from inside its own
  // interpreter, so the frames name its own minified functions and never an
  // API. Matching a buffer to a surface therefore needs the other end: hook
  // the plausible producers and record what each one HANDED BACK. Lengths line
  // the two ends up without any chain matching at all -- 9216 is 48x48x4, and
  // a getImageData that returns exactly that is the owner of that encode.
  //
  // Lengths and dimensions only, never bytes. A recorder that copied pixels
  // into a string would put them back into the realm and change the payload
  // being measured; the r2 hooks did exactly that once and inverted the sign
  // of the difference.
  function wrapProducer(owner, key, label, describeOut) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        var out = original.apply(this === undefined ? globalThis : this, arguments);
        var lim, st;
        try { lim = Error.stackTraceLimit; Error.stackTraceLimit = 200; } catch (e) { /* frozen */ }
        try { st = String(new Error().stack || '').slice(0, 60000); } catch (e) { /* no stack */ }
        try { Error.stackTraceLimit = lim; } catch (e) { /* frozen */ }
        var meta;
        try { meta = describeOut(out, arguments, this) || {}; } catch (e) { meta = { err: 1 }; }
        emit({ k: 'produce', a: { t: label, n: meta.n === undefined ? -1 : meta.n },
               meta: meta, stack: st });
        return out;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  var imageData = function (o) {
    return { n: o && o.data ? o.data.length : -1, w: o && o.width, h: o && o.height };
  };
  // Both context flavours: a document realm has the first, a worker the second,
  // and the payload is assembled in a worker.
  try { wrapProducer(globalThis.CanvasRenderingContext2D && globalThis.CanvasRenderingContext2D.prototype,
                     'getImageData', 'getImageData', imageData); } catch (e) {}
  try { wrapProducer(globalThis.OffscreenCanvasRenderingContext2D && globalThis.OffscreenCanvasRenderingContext2D.prototype,
                     'getImageData', 'offscreen.getImageData', imageData); } catch (e) {}
  try { wrapProducer(globalThis.CanvasRenderingContext2D && globalThis.CanvasRenderingContext2D.prototype,
                     'measureText', 'measureText',
                     function (o, a) { return { n: -1, text: String(a[0]).length, width: o && o.width }; }); } catch (e) {}
  try { wrapProducer(globalThis.HTMLCanvasElement && globalThis.HTMLCanvasElement.prototype,
                     'toDataURL', 'toDataURL', function (o) { return { n: o ? o.length : -1 }; }); } catch (e) {}
  // readPixels writes into the caller's buffer rather than returning one, so
  // the interesting value is the argument.
  var readPixels = function (o, a) {
    var b = a[6];
    return { n: b ? (b.byteLength !== undefined ? b.byteLength : b.length) : -1, w: a[2], h: a[3] };
  };
  try { wrapProducer(globalThis.WebGLRenderingContext && globalThis.WebGLRenderingContext.prototype,
                     'readPixels', 'gl.readPixels', readPixels); } catch (e) {}
  try { wrapProducer(globalThis.WebGL2RenderingContext && globalThis.WebGL2RenderingContext.prototype,
                     'readPixels', 'gl2.readPixels', readPixels); } catch (e) {}
  try { wrapProducer(globalThis.AudioBuffer && globalThis.AudioBuffer.prototype,
                     'getChannelData', 'getChannelData',
                     function (o) { return { n: o ? o.byteLength : -1, len: o ? o.length : -1 }; }); } catch (e) {}

  // One of the fifteen -- 4096 bytes of repeating 00 00 00 ff, so 32x32 opaque
  // black -- comes from none of the producers above. Rather than guess at more
  // readback APIs, ask the cheaper question: which surfaces does the guard
  // create at all? A 32x32 canvas names the buffer even if the read that
  // emptied it is never caught.
  try {
    wrapProducer(globalThis.OffscreenCanvas && globalThis.OffscreenCanvas.prototype, 'getContext',
                 'offscreen.getContext',
                 function (o, a, self) { return { n: -1, type: String(a[0]),
                                                  w: self && self.width, h: self && self.height }; });
  } catch (e) {}
  try {
    wrapProducer(globalThis.HTMLCanvasElement && globalThis.HTMLCanvasElement.prototype, 'getContext',
                 'canvas.getContext',
                 function (o, a, self) { return { n: -1, type: String(a[0]),
                                                  w: self && self.width, h: self && self.height }; });
  } catch (e) {}
  try {
    wrapProducer(globalThis, 'createImageBitmap', 'createImageBitmap',
                 function (o, a) { return { n: -1, src: a[0] && a[0].constructor && a[0].constructor.name }; });
  } catch (e) {}
  try {
    wrapProducer(globalThis.OffscreenCanvas && globalThis.OffscreenCanvas.prototype, 'transferToImageBitmap',
                 'transferToImageBitmap',
                 function (o, a, self) { return { n: -1, w: self && self.width, h: self && self.height }; });
  } catch (e) {}

  // The WebGPU walk. B128 put the 4096-byte buffer on the webgpu collector --
  // three records at index 0 of the collectors' Promise.all and nothing else --
  // but naming the collector does not say how it gets from a 300x150 canvas to
  // 32x32 pixels, and our arm has all the objects and none of the pixels. So
  // follow the whole chain: adapter, device, texture, encoder, buffer, and the
  // mapped range the bytes are finally read out of.
  //
  // Behind a flag because it is a dozen more wrappers on a path the default
  // capture does not need, and every wrapper is a chance to change what the
  // page decides.
  if (${webgpu ? 'true' : 'false'}) (function () {
    var g = globalThis.navigator && globalThis.navigator.gpu;
    // requestAdapter/requestDevice answer promises, so what is worth recording
    // is what they RESOLVED to, not the promise.
    function wrapAsync(owner, key, label, describeOut) {
      if (!owner) return;
      var original;
      try { original = owner[key]; } catch (e) { return; }
      if (typeof original !== 'function') return;
      try {
        owner[key] = disguise(function () {
          var args = arguments;
          var self = this;
          var out = original.apply(this === undefined ? globalThis : this, arguments);
          if (out && typeof out.then === 'function') {
            out.then(function (v) {
              var meta;
              try { meta = describeOut(v, args, self) || {}; } catch (e) { meta = { err: 1 }; }
              emit({ k: 'produce', a: { t: label, n: meta.n === undefined ? -1 : meta.n }, meta: meta });
            }, function (e) {
              emit({ k: 'produce', a: { t: label, n: -1 },
                     meta: { rejected: String(e && e.message).slice(0, 80) } });
            });
          }
          return out;
        }, original);
      } catch (e) { /* non-writable */ }
    }
    // GPUExtent3D is either a dict with width/height or a plain array, and the
    // first reading here recorded neither because it only tried the dict.
    var extent = function (s) {
      if (!s) return {};
      if (typeof s.length === 'number') return { w: s[0], h: s[1], d: s[2] };
      return { w: s.width, h: s.height, d: s.depthOrArrayLayers };
    };
    var dims = function (o, a) {
      var e = extent(a[0] && a[0].size);
      return { n: -1, w: e.w, h: e.h, d: e.d, fmt: a[0] && a[0].format,
               usage: a[0] && a[0].usage };
    };
    // One of the five requestAdapter calls answers null on Chrome, so the
    // options matter as much as the result: a probe that expects null is a
    // reading in its own right, and an arm that hands back an adapter there
    // has answered a question Chrome answered the other way.
    try { wrapAsync(g, 'requestAdapter', 'gpu.requestAdapter',
                    function (v, a) { return { n: -1, got: String(v),
                                               vendor: v && v.info && v.info.vendor,
                                               opts: a[0] ? JSON.stringify(a[0]) : null }; }); } catch (e) {}
    try { wrapAsync(globalThis.GPUAdapter && globalThis.GPUAdapter.prototype, 'requestDevice', 'adapter.requestDevice',
                    function (v) { return { n: -1, got: String(v) }; }); } catch (e) {}
    try { wrapProducer(globalThis.GPUDevice && globalThis.GPUDevice.prototype, 'createTexture',
                       'device.createTexture', dims); } catch (e) {}
    try { wrapProducer(globalThis.GPUDevice && globalThis.GPUDevice.prototype, 'createBuffer',
                       'device.createBuffer',
                       function (o, a) { return { n: a[0] && a[0].size, usage: a[0] && a[0].usage }; }); } catch (e) {}
    try { wrapProducer(globalThis.GPUDevice && globalThis.GPUDevice.prototype, 'createRenderPipeline',
                       'device.createRenderPipeline', function () { return { n: -1 }; }); } catch (e) {}
    try { wrapProducer(globalThis.GPUQueue && globalThis.GPUQueue.prototype, 'submit',
                       'queue.submit', function (o, a) { return { n: a[0] ? a[0].length : -1 }; }); } catch (e) {}
    // The render pass is where the pixels come from, and its loadOp/clearValue
    // is the part reproducible without a rasteriser: 224 of Chrome's 256 pixels
    // are one flat colour, and only 32 are actually drawn.
    try { wrapProducer(globalThis.GPUCommandEncoder && globalThis.GPUCommandEncoder.prototype,
                       'beginRenderPass', 'beginRenderPass',
                       function (o, a) {
                         var ca = (a[0] && a[0].colorAttachments) || [];
                         return { n: ca.length, ops: ca.map(function (c) {
                           return { load: c && c.loadOp, store: c && c.storeOp,
                                    clear: c && c.clearValue ? JSON.stringify(c.clearValue) : null };
                         }) };
                       }); } catch (e) {}
    try { wrapProducer(globalThis.GPURenderPassEncoder && globalThis.GPURenderPassEncoder.prototype,
                       'draw', 'pass.draw',
                       function (o, a) { return { n: a[0], inst: a[1] }; }); } catch (e) {}
    try { wrapProducer(globalThis.GPUCommandEncoder && globalThis.GPUCommandEncoder.prototype,
                       'copyTextureToBuffer', 'copyTextureToBuffer',
                       function (o, a) { var e = extent(a[2]);
                                         return { n: -1, w: e.w, h: e.h,
                                                  bpr: a[1] && a[1].bytesPerRow,
                                                  rpi: a[1] && a[1].rowsPerImage }; }); } catch (e) {}
    try { wrapAsync(globalThis.GPUBuffer && globalThis.GPUBuffer.prototype, 'mapAsync', 'buffer.mapAsync',
                    function (v, a, self) { return { n: self && self.size, mode: a[0] }; }); } catch (e) {}
    // The last step: the bytes leave WebGPU through here.
    try { wrapProducer(globalThis.GPUBuffer && globalThis.GPUBuffer.prototype, 'getMappedRange',
                       'getMappedRange',
                       function (o) { return { n: o ? o.byteLength : -1 }; }); } catch (e) {}
  })();

  var censusDone = false;
  function surfaceCensus(bodyLen) {
    if (censusDone || !bodyLen || bodyLen < 20000) return;
    censusDone = true;
    var out = { bodyLen: bodyLen };
    try {
      var es = performance.getEntries();
      out.entries = es.length;
      var nb = 0, tb = 0;
      for (var i = 0; i < es.length; i++) {
        nb += String(es[i].name || '').length;
        tb += String(es[i].entryType || '').length;
      }
      out.entryNameBytes = nb;
      out.entryTypeBytes = tb;
    } catch (e) { out.entriesErr = String(e && e.message).slice(0, 60); }
    try {
      var names = Object.getOwnPropertyNames(globalThis);
      out.globals = names.length;
      var gb = 0;
      for (var j = 0; j < names.length; j++) gb += names[j].length;
      out.globalNameBytes = gb;
    } catch (e) { out.globalsErr = String(e && e.message).slice(0, 60); }
    emit({ k: 'surface', a: out,
           url: String((globalThis.location || {}).href || '?').slice(0, 120) });
  }

  // What the body ends up being, whichever transport carries it -- the anchor
  // that says which of the records above is the one that became the POST.
  try {
    wrapMethod(globalThis.XMLHttpRequest && globalThis.XMLHttpRequest.prototype, 'send', 'xhr.send', 0);
  } catch (e) {}
  try {
    var origFetch = globalThis.fetch;
    if (typeof origFetch === 'function') {
      globalThis.fetch = disguise(function (input, init) {
        try {
          var body = init && init.body !== undefined ? init.body
            : (input && typeof input === 'object' ? input.body : undefined);
          record('fetch', body, String((input && input.url) || input || '').slice(0, 200));
        } catch (e) { /* keep going */ }
        return origFetch.apply(this === undefined ? globalThis : this, arguments);
      }, origFetch);
    }
  } catch (e) {}

  // The round-2 hooks. Everything above watches a funnel the payload passes
  // through; these watch the assembly itself, and they only exist when --r2
  // asked for them.
  if (${r2 ? 'true' : 'false'}) (function () {
    var R2_MIN = ${R2_MIN};
    var left = ${R2_BUDGET};
    var origCode = String.prototype.charCodeAt;
    var origJoin = Array.prototype.join;
    var seen = Object.create(null);
    // Cheap enough to run per character: a length test, then two code units.
    function note(label, s) {
      var n = s.length;
      if (n < R2_MIN || left <= 0) return;
      var key = n + ':' + origCode.call(s, 0) + ':' + origCode.call(s, n - 1);
      if (seen[key]) return;
      seen[key] = 1;
      left--;
      if (n >= 900) snapCookie();
      var rec = { k: label, a: { t: 'str', n: n, v: String(s) },
                  url: String((globalThis.location || {}).href || '?').slice(0, 120) };
      // Six channels came back negative on where the long token comes from, so
      // stop asking where it was BUILT and ask who is READING it: a stack taken
      // at the first sighting names the call site in the guard's own program,
      // line and column, which is a file we can then go and read.
      if (TOKEN_RE.test(rec.a.v)) {
        try { rec.stack = String(new Error().stack || '').slice(0, 2000); } catch (e) { /* no stack */ }
      }
      emit(rec);
    }
    // Whether an input that differs between the arms is a cause or an effect
    // turns on where it came from. A string the page assembled is a cause; a
    // string the server handed it is the shape of a decision already made
    // before this round. The cookie jar is the difference, so snapshot it
    // alongside the records rather than in a second run that would have its own
    // session and its own tokens.
    // 43 chars, a unix second count, 1.2.1.1, then a blob: Cloudflare's own
    // token grammar, and the shape of the one input in the round-2 window that
    // is 149 bytes longer on this engine on every run.
    var TOKEN_RE = /^[A-Za-z0-9._-]{20,}-1[0-9]{9}-1\.[0-9]\.[0-9]\.[0-9]-/;
    var cookieSeen = Object.create(null);
    function snapCookie() {
      try {
        var c = (globalThis.document || {}).cookie;
        if (typeof c !== 'string' || cookieSeen[c.length]) return;
        cookieSeen[c.length] = 1;
        emit({ k: 'r2.cookie', a: { t: 'str', n: c.length, v: c },
               url: String((globalThis.location || {}).href || '?').slice(0, 120) });
      } catch (e) { /* opaque realm */ }
    }
    function hotString(key, label) {
      var original = String.prototype[key];
      if (typeof original !== 'function') return;
      try {
        // One declared argument and call() rather than apply(): this runs once
        // per character of a body thousands of characters long, so the wrapper
        // has to cost about what the call it replaces costs.
        String.prototype[key] = disguise(function (i) {
          // The receiver is a boxed String in a sloppy-mode call, so reading .length
          // off it is free but coercing it is not -- only do that once the
          // length says this is a receiver worth recording.
          if (this && this.length >= R2_MIN) { try { note(label, this); } catch (e) {} }
          return original.call(this, i);
        }, original);
      } catch (e) { /* non-writable */ }
    }
    // Where a differing input came from decides whether it is worth chasing,
    // and the only channel left that could have delivered one is the reply to
    // the round before it. The response text is read through a getter, so a
    // getter is where to stand.
    try {
      var xp = globalThis.XMLHttpRequest && globalThis.XMLHttpRequest.prototype;
      ['responseText', 'response'].forEach(function (key) {
        var rt = xp && Object.getOwnPropertyDescriptor(xp, key);
        if (!rt || typeof rt.get !== 'function') return;
        var origGet = rt.get;
        Object.defineProperty(xp, key, {
          configurable: true, enumerable: rt.enumerable,
          set: rt.set,
          get: function () {
            var v = origGet.call(this);
            if (typeof v === 'string' && v.length >= R2_MIN) { try { note('r2.' + key, v); } catch (e) {} }
            return v;
          },
        });
      });
    } catch (e) { /* sealed */ }

    // The other half of the same question: a reply read through fetch rather
    // than XHR. Recording the resolved text costs a promise hop and nothing
    // else -- the page's own then() still sees the value it would have seen.
    try {
      var rp = globalThis.Response && globalThis.Response.prototype;
      if (rp && typeof rp.text === 'function') {
        var origText = rp.text;
        rp.text = disguise(function () {
          var p = origText.apply(this, arguments);
          try {
            p.then(function (v) {
              if (typeof v === 'string' && v.length >= R2_MIN) { try { note('r2.fetchText', v); } catch (e) {} }
            }, function () {});
          } catch (e) { /* not a promise */ }
          return p;
        }, origText);
      }
    } catch (e) { /* sealed */ }

    // The widget is handed its challenge parameters by the page over
    // postMessage, so a string that appears in the widget's realm without any
    // network read or any assembly behind it came across that boundary. An
    // extra listener observes it without displacing the page's own.
    try {
      globalThis.addEventListener('message', function (ev) {
        try {
          var d = ev.data;
          var v = typeof d === 'string' ? d : JSON.stringify(d);
          if (typeof v === 'string' && v.length >= R2_MIN) note('r2.message', v);
        } catch (e) { /* unserialisable */ }
      }, true);
    } catch (e) { /* no listener */ }

    // A parse is cold enough to record both sides of: the text that went in and
    // any long string that came out.
    try {
      var origParse = globalThis.JSON.parse;
      globalThis.JSON.parse = disguise(function (text) {
        var out = origParse.apply(this, arguments);
        try {
          if (typeof text === 'string' && text.length >= R2_MIN) note('r2.parse.in', text);
          if (out && typeof out === 'object') {
            for (var k in out) {
              if (typeof out[k] === 'string' && out[k].length >= R2_MIN) note('r2.parse.' + k, out[k]);
            }
          }
        } catch (e) { /* keep going */ }
        return out;
      }, origParse);
    } catch (e) { /* frozen */ }

    // btoa was already instrumented and atob was not, which leaves the obvious
    // way a token could arrive -- decoded rather than fetched -- unwatched. The
    // URI pair is here for the same reason: all three are cold.
    ['atob', 'decodeURIComponent', 'decodeURI', 'unescape'].forEach(function (key) {
      try {
        var original = globalThis[key];
        if (typeof original !== 'function') return;
        globalThis[key] = disguise(function (a) {
          var out = original.call(globalThis, a);
          if (typeof out === 'string' && out.length >= R2_MIN) { try { note('r2.' + key, out); } catch (e) {} }
          return out;
        }, original);
      } catch (e) { /* frozen */ }
    });

    hotString('charCodeAt', 'r2.charCodeAt');
    hotString('charAt', 'r2.charAt');
    try {
      Array.prototype.join = disguise(function () {
        var out = origJoin.apply(this, arguments);
        if (typeof out === 'string' && out.length >= R2_MIN) {
          try { note('r2.join', out); } catch (e) {}
        }
        return out;
      }, origJoin);
    } catch (e) { /* non-writable */ }
  })();

  // Alongside the fact that the recorder is here: the four realm facts the
  // trampoline's answers turn on. Chrome's clock clamp is 100us normally and
  // 5us in a cross-origin isolated realm, and the widget's answer was the 5us
  // one, so whether that realm is isolated decides whether the clamp is the
  // whole story. The other two gate probes rather than answer them.
  var nav = globalThis.navigator || {};
  emit({ k: 'installed',
         href: String((globalThis.location || {}).href || '?').slice(0, 200),
         worker: typeof globalThis.WorkerGlobalScope !== 'undefined',
         coi: !!globalThis.crossOriginIsolated,
         sec: !!globalThis.isSecureContext,
         sab: typeof globalThis.SharedArrayBuffer,
         opfs: !!(nav.storage && nav.storage.getDirectory) });
})();`;

// The document-realm half. It is the only realm that can be armed before its own
// code runs, and it is where the worker is built, so this is where the worker's
// source text is readable -- and, with --inject-worker, where the recorder can be
// put in front of it.
//
// Both interceptions are Proxies rather than hand-written functions. A Proxy
// keeps `Blob.prototype`, `Blob.name`, `instanceof` and `toString()` answering
// exactly as the original did, with no disguise to maintain.
const WORKER_HOOK = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var INJECT = ${injectWorker ? 'true' : 'false'};
  var PAYLOAD = ${JSON.stringify(CORE)};
  var log = console.log.bind(console);
  // Taken before CORE replaces it, so these records do not each show up as a
  // stringify call of their own with the record as its argument.
  var stringify = JSON.stringify;
  var blobSeq = 0;
  // No ceiling here, unlike the funnel recorder: these fire once per worker
  // built, not once per call, and a truncated program is worth nothing.
  function emit(rec) {
    try { log(MARK + stringify(rec)); } catch (e) { /* unserialisable */ }
  }

  // A blob is worker source when its one part is a string of JavaScript. Rather
  // than guess at that, record every string blob and let the report say which.
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
    if (typeof OrigBlob === 'function') {
      globalThis.Blob = new Proxy(OrigBlob, {
        construct: function (target, args) {
          var src = null;
          try { src = textOf(args[0]); } catch (e) { /* exotic parts */ }
          if (src !== null) {
            // A worker program is tens of kilobytes and a console argument is
            // not a guaranteed-lossless channel at that size, so it goes over in
            // pieces the collector stitches back together.
            var id = 'b' + (blobSeq++);
            emit({ k: 'blob', id: id, n: src.length, type: String((args[1] && args[1].type) || '') });
            for (var off = 0; off < src.length; off += 8192) {
              emit({ k: 'blob.part', id: id, at: off, src: src.slice(off, off + 8192) });
            }
            if (INJECT) {
              try { args = [[PAYLOAD + '\\n' + src], args[1]]; } catch (e) { /* leave it */ }
            }
          }
          return new target(args[0], args[1]);
        },
      });
    }
  } catch (e) { /* non-writable */ }

  // What the document hands the worker, and what comes back, are both plaintext
  // -- and reading them costs the worker nothing, since an extra listener does
  // not displace the page's own.
  try {
    var OrigWorker = globalThis.Worker;
    if (typeof OrigWorker === 'function') {
      globalThis.Worker = new Proxy(OrigWorker, {
        construct: function (target, args) {
          var inst = new target(args[0], args[1]);
          emit({ k: 'worker', url: String(args[0] || '').slice(0, 200) });
          try {
            inst.addEventListener('message', function (ev) {
              var d = ev.data;
              emit({ k: 'worker.onmessage',
                     a: typeof d === 'string' ? { t: 'str', n: d.length, v: d }
                                              : { t: typeof d, n: -1, v: (function () {
                                                    try { return stringify(d); } catch (e) { return undefined; }
                                                  })() } });
            });
          } catch (e) { /* not a message port */ }
          try {
            var origPost = inst.postMessage.bind(inst);
            inst.postMessage = function (d) {
              try {
                emit({ k: 'worker.postMessage',
                       a: typeof d === 'string' ? { t: 'str', n: d.length, v: d }
                                                : { t: typeof d, n: -1, v: (function () {
                                                      try { return stringify(d); } catch (e) { return undefined; }
                                                    })() } });
              } catch (e) { /* keep going */ }
              return origPost.apply(null, arguments);
            };
          } catch (e) { /* frozen */ }
          return inst;
        },
      });
    }
  } catch (e) { /* non-writable */ }
})();`;

// Document realms get the worker hook and the funnels, in that order so the
// hook's own records do not pass through the wrapped stringify. A worker that has
// been injected into gets the funnels alone, prepended to its own source above.
const RECORDER = `${WORKER_HOOK}\n${CORE}`;

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE, min: MIN,
    userAgentOverride: null,
    injectWorker, r2, r2Min: r2 ? R2_MIN : null, webgpu,
    posts: [],       // the fo/ POSTs on the wire, to key the records against
    // Every challenge-platform request, with the two things `posts` cannot
    // answer: WHEN it happened and what came back. The collected payload is a
    // constant per client (8 Chrome runs, one signature, 6 served and 2 not),
    // so whatever decides the verdict is not in the payload -- and the places
    // left to look are the timing of the exchange and the replies that shaped
    // it, including the size of the guard program CF hands back in round 1.
    exchange: [],
};

if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    state.userAgentOverride = await headedUserAgent(PORT + 1);
    console.log(`--headed-ua: ${state.userAgentOverride}`);
}

await runTrace({
    engine, url: URL_, settleMs: SETTLE, port: PORT, recorder: RECORDER, mark: MARK,
    userAgentOverride: state.userAgentOverride, logLevel: arg('--log-level', 'info'), state,
    // The POSTs on the wire are what the records have to be keyed against: a
    // record is only interesting once it is the body of one of these.
    onMessage(msg, st) {
        const p = msg.params ?? {};
        const isChallenge = (u) => /challenge-platform|\/cdn-cgi\//.test(String(u ?? ''));
        if (msg.method === 'Network.requestWillBeSent' && /\/fo\//.test(String(p.request?.url ?? ''))) {
            st.posts.push({
                url: String(p.request.url).slice(0, 120),
                postLen: p.request.postData?.length ?? (p.request.hasPostData ? -1 : 0),
            });
        }
        if (msg.method === 'Network.responseReceived' && /\/fo\//.test(String(p.response?.url ?? ''))) {
            const hdrs = p.response.headers ?? {};
            const verdict = Object.keys(hdrs).filter((k) => /^cf-chl/i.test(k)).sort();
            const last = st.posts[st.posts.length - 1];
            if (last && !last.verdict) last.verdict = verdict.join('+');
        }

        // The exchange, whole. Timestamps are CDP's monotonic seconds, so only
        // differences between them mean anything -- which is what is wanted:
        // every leg is measured against this run's own first challenge request.
        if (msg.method === 'Network.requestWillBeSent' && isChallenge(p.request?.url)) {
            st.exchange.push({
                id: p.requestId,
                t: p.timestamp,
                method: p.request.method,
                url: String(p.request.url).slice(0, 140),
                postLen: p.request.postData?.length ?? (p.request.hasPostData ? -1 : 0),
            });
        }
        if (msg.method === 'Network.responseReceived' && isChallenge(p.response?.url)) {
            const e = st.exchange.find((x) => x.id === p.requestId);
            if (e) {
                const h = p.response.headers ?? {};
                const want = ['cf-ray', 'cf-mitigated', 'cf-cache-status', 'server-timing',
                    'content-length', 'content-type', 'date', 'cf-chl-out', 'cf-chl-gen'];
                e.status = p.response.status;
                e.resT = p.timestamp;
                e.hdr = Object.fromEntries(Object.entries(h)
                    .filter(([k]) => want.includes(k.toLowerCase()))
                    .map(([k, v]) => [k.toLowerCase(), String(v).slice(0, 120)]));
            }
        }
        // Round 1's reply is the guard program itself; its size is the cheapest
        // way to notice CF handing out a different one.
        if (msg.method === 'Network.loadingFinished') {
            const e = st.exchange.find((x) => x.id === p.requestId);
            if (e) { e.doneT = p.timestamp; e.encoded = p.encodedDataLength; }
        }
    },
});

// --- report ---------------------------------------------------------------
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''}${injectWorker ? ' --inject-worker' : ''}${r2 ? ` --r2 --r2-min ${R2_MIN}` : ''}${webgpu ? ' --webgpu' : ''} ===`);
console.log(`realms armed: ${state.realms.filter((r) => r.installed).length}/${state.realms.length}`);
const tally = new Map();
for (const r of state.records) tally.set(r.k, (tally.get(r.k) ?? 0) + 1);
console.log(`records: ${state.records.length}  ${[...tally].map(([k, v]) => `${k}=${v}`).join(' ')}`);
for (const r of state.records.filter((r) => (r.a?.v ?? '').length >= MIN).slice(0, 12)) {
    console.log(`  ${String(r.k).padEnd(18)} ${String(r.a.t).padEnd(5)} n=${String(r.a.n).padStart(7)}`
        + `  ${JSON.stringify((r.a.v ?? '').slice(0, 60))}`);
}
for (const b of state.blobs) {
    console.log(`  blob ${b.id} declared=${b.n} got=${b.src.length}`
        + `${b.gapAt !== undefined ? ` GAP@${b.gapAt}` : ''} type=${JSON.stringify(b.type)}`);
}
for (const p of state.posts) console.log(`  POST ${String(p.postLen).padStart(7)} ${p.verdict ?? '?'}  ${p.url.slice(-40)}`);

// Provenance. Knowing that one of the fifteen encodes carries 9216 bytes does
// not say which surface produced it, and the residual against an honoured
// payload is exactly four of these buffers -- so each one needs an owner. The
// frame printed is the first one that is not this instrument: the wrapper
// itself is always frame 0, and the guard's own program is the next one down.
const provenance = state.records.filter((r) => r.k === 'TextEncoder.encode' || r.k === 'subtle.digest'
    || r.k === 'produce');
if (provenance.length) {
    console.log(`  --- ${provenance.length} encode/digest calls, in call order ---`);
    // A frame reduced to the part that identifies it: the function name and the
    // column, since the whole guard is one minified line and the column is what
    // separates one call site from another.
    const brief = (f) => {
        const m = /^at (.*?) \(.*?:1:(\d+)\)$/.exec(f) ?? /^at (.*?) \(<anonymous>:(\d+):\d+\)$/.exec(f);
        return m ? `${m[1]}@${m[2]}` : f.replace(/^at /, '').slice(0, 40);
    };
    provenance.forEach((r, i) => {
        const frames = String(r.stack ?? '').split('\n').map((s) => s.trim())
            .filter((s) => s.startsWith('at '));
        // Frame 0 is the wrapper installed above -- `disguise` gives it the
        // original's name, so it has to be dropped by position, not by name.
        const guard = frames.slice(1);
        // The top frame is the call site; the bottom is whatever kicked the
        // whole chain off. The middle is the interpreter cycling, which is why
        // only the ends are printed here and the full chain goes to the JSON.
        const kind = r.k === 'produce' ? String(r.a?.t ?? 'produce')
            : (r.k === 'subtle.digest' ? 'digest' : 'encode');
        console.log(`  ${String(i).padStart(2)} ${kind.padEnd(22)}`
            + ` n=${String(r.a?.n ?? -1).padStart(6)} frames=${String(guard.length).padStart(3)}`
            + (r.meta ? `  ${JSON.stringify(r.meta)}` : '')
            + `  site=${brief(guard[0] ?? '')}  bottom=${brief(guard[guard.length - 1] ?? '')}`);
    });
}
const t0 = state.exchange[0]?.t ?? 0;
for (const e of state.exchange) {
    const ms = (x) => (x === undefined ? '    -' : String(Math.round((x - t0) * 1000)).padStart(5));
    console.log(`  ${ms(e.t)}ms ${String(e.method).padEnd(4)} ${String(e.status ?? '-').padEnd(3)}`
        + ` req=${String(e.postLen).padStart(6)} resp=${String(e.encoded ?? -1).padStart(6)}`
        + ` +${ms(e.doneT)}  ${e.url.slice(-46)}`
        + (e.hdr?.['cf-mitigated'] ? `  MITIGATED=${e.hdr['cf-mitigated']}` : ''));
}
// The verdict this run got, on the same criterion cf-token.mjs uses: the ticket
// is handed out to arms that are then refused the page, so `served` reads the
// page itself. Without it a captured plaintext says nothing about which side of
// the decision it sits on -- every capture before this line was of a run whose
// verdict nobody recorded, so the plaintext of an HONOURED payload had never
// been looked at.
//
// It is also the instrument's own honesty check, which the header above asks
// for: run the oracle arm with the wrappers in and see whether it still clears.
state.served = /bypassed/i.test(String(state.final?.text ?? ''));
console.log(`served=${state.served}`);
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.error) {
    // A run that threw is not a reading. Exiting non-zero is the point: a
    // parity failure printed on stdout of a tool that exits 0 is invisible to
    // the loop that called it, and reads exactly like a knob that changed
    // nothing.
    console.log(`ERROR ${state.error}`);
    process.exitCode = 1;
}

if (OUT) await writeRun(OUT, state);
