// How is the widget's round-1 body assembled, and out of what?
//
// `fo-plaintext.mjs` wrapped the funnels a plaintext passes through on its way
// out -- WebCrypto, TextEncoder, JSON.stringify, btoa -- and found none of them
// carrying round 1: in the widget realm, before the first POST, nothing over
// two bytes goes through any of them. `fo-reads.mjs` then wrapped the getters
// instead and found six differences, five of which are now fixed, none of which
// moved the length (README, "Five of the six are closed").
//
// What neither instrument wrapped is the step in between: the one that turns a
// list of collected values into a string. The records `fo-plaintext.mjs` did
// capture say what that step is. Every block of the widget's later rounds
// arrives pipe-joined --
//
//   "0|0|0|0|0|..."                              (1 999 here, 15 361 there)
//   "@keyframes spin { ... }|@keyframes scale..."  (20 367 / 20 696)
//
// -- which is Array.prototype.join, a funnel nobody has wrapped. If round 1 is
// assembled the same way its later siblings are, the join is where the payload
// is last readable in the clear, and the ~112-byte surplus stops being a length
// and becomes a named field.
//
// The same run answers the other open lead for free. The widget is handed its
// challenge parameters by the parent over `postMessage`, and an extra listener
// costs the page nothing because it does not displace its own -- so this also
// writes down every inbound message, which is the second of the two things the
// README leaves unchecked.
//
// Recording stops in each realm at its own first `XMLHttpRequest.send`: only
// what was assembled before the send can be in the body it carried, and
// stopping there is also what keeps a hot funnel like `join` affordable.
//
// Honesty is a measurement, not an argument, and it is the same one as the two
// instruments before this: run the oracle arm with the wrappers in and check it
// still clears.
//
// usage:
//   node tools/fingerprint/fo-join.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--max-records n] [--min n] [--value-cap n]
// env: LP_BIN, CHROME
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: fo-join.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9282' : '9283'));
const OUT = arg('--out', null);
const MAX_RECORDS = Number(arg('--max-records', '4000'));
// A two-element join is a coordinate pair, not a payload. The surplus is 112
// bytes, so anything that could hold it is comfortably above this.
const MIN = Number(arg('--min', '16'));
// Round 1 is ~4 800 characters, so the cap has to clear that or the one record
// worth having arrives truncated.
const VALUE_CAP = Number(arg('--value-cap', '12000'));
const headedUa = has('--headed-ua');

const MARK = '@@FOJN@@';

const RECORDER = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var MAX = ${MAX_RECORDS};
  var MIN = ${MIN};
  var CAP = ${VALUE_CAP};
  var n = 0;
  var log = console.log.bind(console);
  var stringify = JSON.stringify;
  var defineProp = Object.defineProperty;
  // A record is itself a stringify and a console.log, and console.log reads
  // properties, so without the guard the recorder feeds itself.
  var inside = false;
  // Once this realm has sent, nothing assembled afterwards can be in the body
  // that went out, and join is hot enough that recording past the cut would
  // spend the whole budget on rounds nobody is asking about.
  var sent = false;
  var rid = 'j' + Math.random().toString(36).slice(2, 8);
  var seq = 0;

  function emit(rec) {
    if (inside) return;
    inside = true;
    try { rec.r = rid; rec.i = seq++; log(MARK + stringify(rec)); } catch (e) { /* unserialisable */ }
    inside = false;
  }

  function record(key, text, extra) {
    if (inside || sent || n >= MAX) return;
    // A keyOf that answers '@skip' is how a wrapper declines a call it has
    // decided says nothing -- fromCharCode one character at a time.
    if (key === '@skip') return;
    if (typeof text !== 'string' || text.length < MIN) return;
    n++;
    inside = true;
    try {
      var rec = { k: key, n: text.length, v: text.length <= CAP ? text : text.slice(0, CAP), r: rid, i: seq++ };
      if (extra !== undefined) rec.x = extra;
      log(MARK + stringify(rec));
    } catch (e) { /* unserialisable */ }
    inside = false;
  }

  // A wrapper that answers toString() with the native text is a wrapper the
  // page cannot tell from the function it replaced by reading it.
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

  // Wraps a function whose *return value* is the assembled string. The label
  // may be refined per call by keyOf, so one wrapper can separate a join on
  // '|' from a join on ','.
  function wrapProducer(owner, key, label, keyOf) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        var v = original.apply(this === undefined ? globalThis : this, arguments);
        try { record(keyOf ? keyOf(label, arguments, this) : label, v); } catch (e) { /* keep going */ }
        return v;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  var G = globalThis;
  function proto(name) { try { return G[name] && G[name].prototype; } catch (e) { return null; } }

  // The separator is the interesting half of a join: the later rounds all use
  // '|', so a '|' join in round 1 is the same collector speaking.
  wrapProducer(proto('Array'), 'join', 'join', function (label, args) {
    var sep = args.length === 0 || args[0] === undefined ? ',' : String(args[0]);
    return label + '(' + stringify(sep.slice(0, 8)) + ')';
  });
  // Array.prototype.toString is a join(',') the wrapper above does not see,
  // because the spec calls the *original* join, not the property.
  wrapProducer(proto('Array'), 'toString', 'Array.toString');
  // The usual last step of a byte-array-to-string conversion. Called one
  // character at a time it says nothing, so only bulk calls are written down.
  wrapProducer(G.String, 'fromCharCode', 'String.fromCharCode', function (label, args) {
    return args.length >= 32 ? label : '@skip';
  });
  wrapProducer(G, 'encodeURIComponent', 'encodeURIComponent');
  wrapProducer(G, 'btoa', 'btoa');
  wrapProducer(G.JSON, 'stringify', 'JSON.stringify');
  // A collector that builds its own markup reads it back out; both of these
  // hand over a whole subtree as one string.
  wrapProducer(proto('XMLSerializer'), 'serializeToString', 'XMLSerializer.serializeToString');

  // The plaintext is handed to no funnel at all -- but the encoder that turns
  // it into the joined array above has to read it, and it reads it one
  // character at a time. So record the *receiver* of charCodeAt rather than any
  // argument or result: that is the payload one step before it stops being
  // readable. A receiver is written down once, not once per character, which is
  // what makes wrapping something this hot affordable.
  //
  // The wrapper is strict so that a primitive string receiver arrives as a
  // primitive; a sloppy one would box it and every call would pay for the
  // conversion needed to look at it.
  var lastSeen = null;
  function wrapReceiver(owner, key, label, minLen) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        'use strict';
        var s = this;
        if (typeof s === 'string' && s.length >= minLen && s !== lastSeen) {
          lastSeen = s;
          try { record(label, s); } catch (e) { /* keep going */ }
        }
        return original.apply(s, arguments);
      }, original);
    } catch (e) { /* non-writable */ }
  }

  wrapReceiver(proto('String'), 'charCodeAt', 'charCodeAt<-', 200);
  wrapReceiver(proto('String'), 'codePointAt', 'codePointAt<-', 200);
  wrapReceiver(proto('String'), 'split', 'split<-', 200);

  // What the parent hands the widget. An added listener does not displace the
  // page's own, so this reads the challenge parameters at no cost to it.
  try {
    G.addEventListener('message', function (ev) {
      var d = ev.data;
      var text;
      try { text = typeof d === 'string' ? d : stringify(d); } catch (e) { text = '<unserialisable>'; }
      record('message', String(text), String(ev.origin || '').slice(0, 80));
    }, true);
  } catch (e) { /* no window */ }

  // The cut line, and the anchor: the body here is the ciphertext one of the
  // records above may have become.
  try {
    var xhrProto = proto('XMLHttpRequest');
    if (xhrProto) {
      var origSend = xhrProto.send;
      xhrProto.send = disguise(function (body) {
        try {
          if (!sent) {
            emit({ k: '@send', n: typeof body === 'string' ? body.length : -1,
                   v: typeof body === 'string' ? body.slice(0, CAP) : undefined });
          }
          sent = true;
        } catch (e) { /* keep going */ }
        return origSend.apply(this, arguments);
      }, origSend);
    }
  } catch (e) { /* frozen */ }

  emit({ k: '@installed', href: String((G.location || {}).href || '?').slice(0, 200),
         worker: typeof G.WorkerGlobalScope !== 'undefined' });
})();`;

const state = { engine, url: URL_, headedUa, settleMs: SETTLE, maxRecords: MAX_RECORDS, min: MIN };
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
// One realm per `@installed`, in arrival order; everything it assembled before
// its own first send, and the send it went into.
const realms = new Map();
for (const rec of state.records) {
    let r = realms.get(rec.r);
    if (!r) realms.set(rec.r, r = { rid: rec.r, session: rec.session, href: '?', built: [], send: null });
    if (rec.k === '@installed') { r.href = rec.href; r.worker = rec.worker; continue; }
    if (rec.k === '@send') { r.send ??= { n: rec.n, v: rec.v }; continue; }
    r.built.push(rec);
}
state.realmBuilds = [...realms.values()];

console.log(`=== fo-join ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
for (const r of state.realmBuilds) {
    const tally = new Map();
    for (const b of r.built) tally.set(b.k, (tally.get(b.k) ?? 0) + 1);
    console.log(`  realm ${r.rid} ${r.worker ? 'worker ' : ''}built=${r.built.length}`
        + ` send=${r.send ? r.send.n : '-'} ${r.href.slice(0, 80)}`);
    console.log(`    ${[...tally].map(([k, v]) => `${k}=${v}`).join(' ') || '(nothing)'}`);
    for (const b of r.built.filter((x) => x.n >= 64).slice(0, 10)) {
        console.log(`      ${String(b.k).padEnd(24)} n=${String(b.n).padStart(6)}  ${JSON.stringify(b.v.slice(0, 70))}`);
    }
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
