// Which properties does the widget read before its first `fo/` POST, and what
// is it told?
//
// The widget's round-1 telemetry is one ciphertext, so the body cannot be
// diffed -- but the *inputs* can. `fo-plaintext.mjs` wrapped the funnels a
// plaintext would pass through on its way out and found none of them carrying
// it: no WebCrypto, no `btoa`, nothing over 2 bytes through `JSON.stringify` in
// the widget realm before the POST goes out. The payload is assembled and
// encoded by the widget's own code, so the last place it is readable in the
// clear is where each value is *fetched* -- one property getter at a time.
//
// So wrap the getters instead of the funnels. Every accessor on the standard
// prototypes forwards to the original and returns its value unchanged, with a
// record of what it answered; each wrapper's `toString` is made to answer with
// the native source text, same disguise `fo-plaintext.mjs` uses. Whether that
// is honest is a measurement, not an argument: run the oracle arm with the
// wrappers in and check it still clears.
//
// Two diffs come out of one recorder, and they answer the two halves of the
// question separately:
//
//   * the same arm, twice -- any read whose answer changed between runs is a
//     variable-length contribution, which is what the payload's 10-11 byte
//     run-to-run wobble is made of;
//   * the two arms, one sitting -- any read whose answer differs in *length*
//     is a candidate for the ~150-byte gap between them.
//
// Records are cut at the realm's first `XMLHttpRequest.send`, because only the
// reads that happened before it can be in the body it carried.
//
// usage:
//   node tools/fingerprint/fo-reads.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--max-records n] [--per-key n] [--value-cap n]
// env: LP_BIN, CHROME
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: fo-reads.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9272' : '9273'));
const OUT = arg('--out', null);
const MAX_RECORDS = Number(arg('--max-records', '9000'));
// `performance.now` alone is thousands of reads, and the thousandth says nothing
// the fortieth did not. A per-key ceiling keeps one hot accessor from spending
// the whole budget on itself.
const PER_KEY = Number(arg('--per-key', '60'));
const VALUE_CAP = Number(arg('--value-cap', '4000'));
const headedUa = has('--headed-ua');

const MARK = '@@FORD@@';

const RECORDER = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var MAX = ${MAX_RECORDS};
  var PER_KEY = ${PER_KEY};
  var CAP = ${VALUE_CAP};
  var n = 0;
  var perKey = {};
  var log = console.log.bind(console);
  var stringify = JSON.stringify;
  var getOwn = Object.getOwnPropertyNames;
  var getDesc = Object.getOwnPropertyDescriptor;
  var defineProp = Object.defineProperty;
  // A record is itself a stringify and a console.log, and console.log reads
  // properties -- without the guard the recorder records itself.
  var inside = false;
  var rid = 'r' + Math.random().toString(36).slice(2, 8);
  var seq = 0;

  function emit(rec) {
    if (inside) return;
    inside = true;
    try { rec.r = rid; rec.i = seq++; log(MARK + stringify(rec)); } catch (e) { /* unserialisable */ }
    inside = false;
  }

  // What a value contributes to a payload is its text, so that is what gets
  // measured: length always, the text itself when it is short enough to read.
  function brief(v) {
    try {
      if (v === null) return { t: 'null' };
      var t = typeof v;
      if (t === 'undefined' || t === 'boolean') return { t: t, v: String(v) };
      if (t === 'number') { var s = String(v); return { t: 'num', n: s.length, v: s }; }
      if (t === 'string') return { t: 'str', n: v.length, v: v.length <= CAP ? v : v.slice(0, CAP) };
      if (t === 'function') return { t: 'fn' };
      if (t === 'symbol' || t === 'bigint') return { t: t, v: String(v) };
      var j;
      try { j = stringify(v); } catch (e) { j = null; }
      if (typeof j === 'string') return { t: 'obj', n: j.length, v: j.length <= CAP ? j : j.slice(0, CAP) };
      return { t: 'obj', n: -1, v: Object.prototype.toString.call(v) };
    } catch (e) { return { t: 'unreadable' }; }
  }

  function record(key, value) {
    if (inside || n >= MAX) return;
    var c = perKey[key] || 0;
    if (c >= PER_KEY) { perKey[key] = c + 1; return; }
    perKey[key] = c + 1;
    n++;
    inside = true;
    try {
      var b = brief(value);
      b.k = key; b.r = rid; b.i = seq++;
      log(MARK + stringify(b));
    } catch (e) { /* unserialisable */ }
    inside = false;
  }

  function disguise(wrapper, original) {
    var native_ = 'function ' + (original.name || '') + '() { [native code] }';
    try {
      defineProp(wrapper, 'name', { value: original.name, configurable: true });
      defineProp(wrapper, 'length', { value: original.length, configurable: true });
      wrapper.toString = function () { return native_; };
      wrapper.toString.toString = function () { return 'function toString() { [native code] }'; };
    } catch (e) { /* frozen */ }
    return wrapper;
  }

  function wrapAccessors(owner, label) {
    if (!owner) return;
    var names;
    try { names = getOwn(owner); } catch (e) { return; }
    for (var i = 0; i < names.length; i++) {
      (function (key) {
        var d;
        try { d = getDesc(owner, key); } catch (e) { return; }
        // A non-configurable accessor cannot be replaced, and a data property
        // is read without ever calling anything -- neither is reachable here,
        // and pretending otherwise would put silent holes in the record.
        if (!d || !d.configurable || typeof d.get !== 'function') return;
        var g = d.get;
        try {
          defineProp(owner, key, {
            configurable: true,
            enumerable: d.enumerable,
            set: d.set,
            get: disguise(function () {
              var v = g.call(this);
              try { record(label + '.' + key, v); } catch (e) { /* keep going */ }
              return v;
            }, g),
          });
        } catch (e) { /* refused */ }
      })(names[i]);
    }
  }

  function wrapMethod(owner, key, label) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        var v = original.apply(this === undefined ? globalThis : this, arguments);
        try { record(label, v); } catch (e) { /* keep going */ }
        return v;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  var G = globalThis;
  function proto(name) { try { return G[name] && G[name].prototype; } catch (e) { return null; } }

  // The global object first: a browser puts innerWidth, devicePixelRatio,
  // screenX and friends here as own accessors, and they are read by name with
  // no receiver to give them away.
  wrapAccessors(G, 'window');
  wrapAccessors(proto('Window'), 'Window');
  wrapAccessors(proto('Navigator'), 'navigator');
  wrapAccessors(proto('WorkerNavigator'), 'navigator');
  wrapAccessors(proto('Screen'), 'screen');
  wrapAccessors(proto('Performance'), 'performance');
  wrapAccessors(proto('History'), 'history');
  wrapAccessors(proto('Document'), 'document');
  wrapAccessors(proto('Element'), 'Element');
  wrapAccessors(proto('HTMLElement'), 'HTMLElement');
  wrapAccessors(proto('MediaQueryList'), 'MediaQueryList');

  // Methods whose *return value* is the datum rather than a side effect.
  wrapMethod(proto('Performance'), 'now', 'performance.now()');
  wrapMethod(proto('Date'), 'getTimezoneOffset', 'Date.getTimezoneOffset()');
  wrapMethod(proto('Date'), 'toString', 'Date.toString()');
  wrapMethod(G.Date, 'now', 'Date.now()');
  wrapMethod(G, 'matchMedia', 'matchMedia()');
  wrapMethod(proto('HTMLCanvasElement'), 'toDataURL', 'canvas.toDataURL()');
  wrapMethod(proto('WebGLRenderingContext'), 'getParameter', 'gl.getParameter()');
  wrapMethod(proto('WebGL2RenderingContext'), 'getParameter', 'gl2.getParameter()');
  wrapMethod(G.Intl && G.Intl.DateTimeFormat && G.Intl.DateTimeFormat.prototype,
             'resolvedOptions', 'Intl.DateTimeFormat.resolvedOptions()');
  wrapMethod(G.Math, 'random', 'Math.random()');

  // Enumeration, which the accessor wrappers cannot see. A collector that asks
  // for a whole name list gets one string per call and none of it passes a
  // getter, so a surplus made of names -- an engine with globals the reference
  // does not have -- is invisible above and visible here. The brand of the
  // argument goes in the key, so getOwnPropertyNames of window is its own row.
  function wrapEnumerator(owner, key, label) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function (target) {
        var v = original.apply(this === undefined ? globalThis : this, arguments);
        try {
          var brand = 'other';
          try { brand = Object.prototype.toString.call(target); } catch (e) { /* exotic */ }
          record(label + brand, v);
        } catch (e) { /* keep going */ }
        return v;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  wrapEnumerator(Object, 'getOwnPropertyNames', 'Object.getOwnPropertyNames');
  wrapEnumerator(Object, 'getOwnPropertySymbols', 'Object.getOwnPropertySymbols');
  wrapEnumerator(Object, 'keys', 'Object.keys');
  wrapEnumerator(Object, 'values', 'Object.values');
  wrapEnumerator(Object, 'entries', 'Object.entries');
  wrapEnumerator(Object, 'getOwnPropertyDescriptors', 'Object.getOwnPropertyDescriptors');
  wrapEnumerator(Object, 'getPrototypeOf', 'Object.getPrototypeOf');
  wrapEnumerator(G.Reflect, 'ownKeys', 'Reflect.ownKeys');

  // What a function says about itself. A page that reads the source text of a
  // built-in is checking for a wrapper, and a page that reads its own is
  // hashing it.
  wrapMethod(proto('Function'), 'toString', 'Function.toString()');

  // The cut line. Only reads that happened before the first send can be in the
  // body it carried, so the report needs to know where it was.
  try {
    var xhrProto = proto('XMLHttpRequest');
    if (xhrProto) {
      var origSend = xhrProto.send;
      xhrProto.send = disguise(function (body) {
        try {
          emit({ k: '@send', n: typeof body === 'string' ? body.length : -1 });
        } catch (e) { /* keep going */ }
        return origSend.apply(this, arguments);
      }, origSend);
    }
  } catch (e) { /* frozen */ }

  emit({ k: '@installed', href: String((G.location || {}).href || '?').slice(0, 200),
         worker: typeof G.WorkerGlobalScope !== 'undefined' });
})();`;

const state = { engine, url: URL_, headedUa, settleMs: SETTLE, maxRecords: MAX_RECORDS, perKey: PER_KEY };
if (headedUa) {
    if (engine !== 'chrome') {
        console.error('--headed-ua only makes sense with the chrome engine');
        process.exit(2);
    }
    state.userAgentOverride = await headedUserAgent(PORT + 1);
    console.log(`--headed-ua: ${state.userAgentOverride}`);
}

await runTrace({
    engine, url: URL_, settleMs: SETTLE, port: PORT,
    recorder: RECORDER, mark: MARK,
    userAgentOverride: state.userAgentOverride ?? null,
    state,
});

// --- report ---------------------------------------------------------------
// One realm per `@installed`, in arrival order, and each realm's reads cut at
// its own first send.
const realms = new Map();
for (const rec of state.records) {
    let r = realms.get(rec.r);
    if (!r) realms.set(rec.r, r = { rid: rec.r, session: rec.session, href: '?', reads: [], sends: [] });
    if (rec.k === '@installed') { r.href = rec.href; r.worker = rec.worker; continue; }
    if (rec.k === '@send') { r.sends.push({ i: rec.i, n: rec.n }); continue; }
    r.reads.push(rec);
}
state.realmReads = [...realms.values()].map((r) => {
    const cut = r.sends.length ? r.sends[0].i : Infinity;
    const before = r.reads.filter((x) => x.i < cut);
    return { ...r, readsBeforeFirstSend: before.length, totalReads: r.reads.length };
});

console.log(`=== fo-reads ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
for (const r of state.realmReads) {
    console.log(`  realm ${r.rid} ${r.worker ? 'worker ' : ''}reads=${r.totalReads}`
        + ` before-first-send=${r.readsBeforeFirstSend}`
        + ` sends=[${r.sends.map((s) => s.n).join(',')}] ${r.href.slice(0, 90)}`);
}
console.log(`FINAL ${JSON.stringify(state.final)}`);
if (state.exceptions?.length) {
    console.log(`exceptions(${state.exceptions.length}): ${state.exceptions.slice(0, 4).join(' | ')}`);
}
if (state.error) {
    // A run that threw is not a reading. Exiting non-zero is the point: a
    // parity failure printed on stdout of a tool that exits 0 is invisible to
    // the loop that called it, and reads exactly like a knob that changed
    // nothing.
    console.log(`ERROR ${state.error}`);
    process.exitCode = 1;
}

if (OUT) await writeRun(OUT, state);
