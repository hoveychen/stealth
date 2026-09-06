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
//        [--r2] [--r2-min n] [--r2-budget n]
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
  function record(label, value, extra) {
    if (inside || n++ > ${MAX_RECORDS}) return;
    inside = true;
    try {
      var rec = { k: label, a: describe(value) };
      if (extra) rec.url = extra;
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

  function wrapMethod(owner, key, label, argIndex) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        try { record(label, arguments[argIndex]); } catch (e) { /* keep going */ }
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
  try { wrapMethod(globalThis.crypto && globalThis.crypto.subtle, 'digest', 'subtle.digest', 1); } catch (e) {}
  try { wrapMethod(globalThis.TextEncoder && globalThis.TextEncoder.prototype, 'encode', 'TextEncoder.encode', 0); } catch (e) {}
  try { wrapMethod(globalThis.JSON, 'stringify', 'JSON.stringify', 0); } catch (e) {}
  try { wrapMethod(globalThis, 'btoa', 'btoa', 0); } catch (e) {}

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
    injectWorker, r2, r2Min: r2 ? R2_MIN : null,
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
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''}${injectWorker ? ' --inject-worker' : ''}${r2 ? ` --r2 --r2-min ${R2_MIN}` : ''} ===`);
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
