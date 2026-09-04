// Where do the two engines first answer a Turnstile question differently?
//
// The widget document is a bytecode VM. Its property names are not in the
// source -- they are assembled character by character at runtime out of a table
// indexed by running VM state, so one host call answering differently poisons
// every name decoded after it. That is why the `reading 'call'` throw the
// previous sessions chased is a *symptom*: by the time it fires, the divergence
// is thousands of operations old (README, "`bGgjP8` was never installed").
//
// So stop sampling at the throw and record the whole run instead. This patches
// the VM's own member-access opcode in a *captured* copy of the document, runs
// the identical patched file in both engines, and writes an ordered trace of
// every (receiver, decoded name) -> answer the VM asked the host. `diff` then
// reports the first entry where the two disagree, which is the divergence
// itself rather than its last consequence.
//
// WHY PATCH THE OPCODE AND NOT THE HOST. The obvious instrument -- accessors
// over every builtin, or a proxy in the prototype chain -- changes what the page
// reads, and exception-frames.mjs already has the scar to prove it (swapping the
// prototype above CSSStyleDeclaration turns every CSS property undefined in BOTH
// engines and moves the failure somewhere else entirely). Rewriting the
// interpreter's own ternary observes the exact values the VM computes and leaves
// the host untouched, so both engines see a stock browser.
//
// The opcode, in the obfuscated source, is one of these six shapes:
//
//   oQ = oq === void 0        ? oQ : oq[oQ]        // three spellings of the
//   og = void 0 === oQ        ? oy : oQ[oy]        // same undefined check, and
//   og = U[UB(ar.om)](oq,void 0) ? oy : oq[oy]     // one behind a helper
//
// and the rewrite only ever touches the two *branches*, never the condition:
//
//   ... ? __vt(oq, oQ, 1) : __vt(oq, oQ, 0)
//
// so whatever the condition means is still decided by the page's own code. The
// true branch returns the name unchanged (a receiverless call passes the name
// through); the false branch does the read, once, and returns it.
//
// DETERMINISM FIRST, OR THE DIFF IS ALL NOISE. `Date.now`, `Math.random`,
// `performance.now` and `crypto.getRandomValues` feed the same VM state that
// picks the next property name, so two runs of the *same* engine diverge on
// their own. The bootstrap replaces all four with identical fixed sequences in
// both engines (`--no-determinize` to see the raw thing). What survives that is
// a host answer that genuinely differs.
//
// THE WIDGET REFUSES TO RUN UNFRAMED, which is why the first replay looked like
// a dead end. Served top-level it takes an early bail --
//
//   if (p[…] == p[…] || !p[…]) return void(…, wX(…), …)     // top == self
//
// -- and `wX` is the error renderer, which appends into a container the host
// page was supposed to provide and gets `null`. That is the whole of the
// "Chrome dies on reading 'appendChild'" note in the README: not a Chrome
// quirk, both engines do it, and it happens *before* the VM starts (zero
// opcodes recorded). So the replay serves a parent page on one origin and the
// widget from another, exactly like the live embedding, and `--top-level`
// exists only to reproduce that dead end on purpose.
//
// The trace comes back over the console rather than `Runtime.evaluate`: the
// widget lives in a cross-origin child realm that a main-frame evaluate cannot
// reach, while `Runtime.consoleAPICalled` arrives from every realm in both
// engines (which is how exception-frames.mjs read the widget's throw).
//
// WHAT `--postmessage` CAN AND CANNOT SEE. The last unexplained step at this
// station is in the *parent* realm: the widget posts its large second `fo/`
// round and the parent then never posts the solved challenge (README, "the
// parent is never told to finish"). The step between them crosses the frame
// boundary, so it is a `postMessage` and not a call inside either realm.
//
// A cross-origin send cannot be seen from the sender. `parent.postMessage` on a
// cross-origin WindowProxy is not the sending realm's own `postMessage` -- and
// the realm's own is where Chrome keeps Window's operations, as own properties
// of the global object rather than on `Window.prototype` -- so no sender-side
// wrap is on that path. Measured on a two-port parent/child fixture, in both
// engines: the child's `parent.postMessage` and the parent's
// `e.source.postMessage` are recorded by neither sender and by both receivers.
//
// So the instrument reads the receiving side: a capture-phase `message`
// listener, installed before any page script in every realm, which sees every
// message actually delivered in either direction and changes nothing about
// delivery. Its blind spot is the send that is *dropped* -- a `targetOrigin`
// that does not match the receiver fails silently at the sender and appears
// nowhere here, though Chrome logs it and `state.console` keeps that.
// `--postmessage-sends` adds the two sender-side wraps that can be had (the
// realm's own `postMessage`, and `MessagePort.prototype.postMessage` for a
// transferred port, whose object does live in the receiving realm) and is a
// separate flag because they change function identity, the same reason
// `--reach` is one.
//
// WHAT THIS ACTUALLY FOUND, so the next reader does not re-run it expecting a
// trace: offline the widget records **zero** opcodes in both engines, because
// its VM entry point is runProgram(base64Program, window) and the program is an
// argument the host page's api.js supplies over postMessage. `--reach` is what
// produced the answer instead -- it wraps every global the widget installs,
// counts calls, keeps first-call arguments, and checks whether a declaration
// handed to createScript actually took. See README, "eval does not unwrap a
// TrustedScript".
//
// usage:
//   node tools/fingerprint/vm-trace.mjs <lightpanda|chrome> [--doc path]
//        [--settle ms] [--cap n] [--out results/x.json] [--port n]
//        [--top-level] [--no-determinize] [--reach] [--kick name|''] [--kick-after ms]
//        [--postmessage] [--postmessage-sends]
//        [--url live-url] [--attach-frames] [--same-process] [--no-patch] [--serve]
//        [--headed] [--chrome-arg SWITCH]... [--log-level debug] [--keep]
//   node tools/fingerprint/vm-trace.mjs diff <a.json> <b.json> [--window 8]
// env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? fallback : process.argv[i + 1];
};
const has = (name) => process.argv.includes(name);
// Repeatable, straight through to the browser. `--chrome-arg
// --user-agent=<the headed string>` is what makes the headless reference a
// browser this guard accepts (README, "the headless tell is one word").
const chromeArgs = process.argv.reduce(
    (acc, a, i) => (a === '--chrome-arg' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc),
    [],
);

// Paths land under tools/fingerprint/ unless they already say tools/, matching
// exception-frames.mjs -- an --out that silently wrote somewhere else once put
// a run's results in the repo root.
const resolveOut = (p) => path.resolve(REPO, p.startsWith('tools/') ? p : path.join('tools/fingerprint', p));

const mode = process.argv[2];
if (mode === 'diff') {
    await diffMain();
    process.exit(0);
}
if (mode !== 'lightpanda' && mode !== 'chrome') {
    console.error('usage: vm-trace.mjs <lightpanda|chrome> [--doc path] [--settle ms] [--out path]');
    console.error('       vm-trace.mjs diff <a.json> <b.json> [--window 8]');
    process.exit(2);
}
const engine = mode;

const SETTLE = Number(arg('--settle', '20000'));
const CAP = Number(arg('--cap', '120000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9240' : '9241'));
// Two ports, so the widget is a genuinely cross-origin child the way it is
// live. Same host, different port, is a different origin.
const PARENT_PORT = PORT + 100;
const DOC_PORT = PORT + 200;
const TOP_LEVEL = has('--top-level');
const DETERMINIZE = !has('--no-determinize');
// `--kick ''` to leave the widget alone and watch it wait.
const KICK = arg('--kick', 'runProgram');
const KICK_MS = Number(arg('--kick-after', '1500'));
const LIGHTPANDA = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Default to the first captured widget document. They are four different
// obfuscations of the same bundle, so the choice matters only in that both
// engines must be given the same one.
const CAPTURED = path.join(HERE, 'results/exc-src4');
const docPath = arg('--doc', null)
    ? path.resolve(REPO, arg('--doc'))
    : path.join(CAPTURED, (await fs.readdir(CAPTURED)).sort()[0]);

// ---------------------------------------------------------------------------
// The patch
// ---------------------------------------------------------------------------

// `? name : recv[name]` with the same identifier in both places. The condition
// in front of the `?` is deliberately not matched: there are at least three
// spellings of it across the six sites and one of them hides behind a helper
// call, and none of that has to be understood to instrument the branches.
const OPCODE = /\?\s*([A-Za-z_$][\w$]*)\s*:\s*([A-Za-z_$][\w$]*)\[\1\]/g;

function patch(source) {
    const sites = [];
    const patched = source.replace(OPCODE, (whole, name, recv, offset) => {
        sites.push({ offset, text: whole });
        return `?__vt(${recv},${name},1):__vt(${recv},${name},0)`;
    });
    return { patched, sites };
}

// ---------------------------------------------------------------------------
// The instrument, injected before any page script via CDP (so it needs no
// nonce, and the document's own CSP -- which allows only its one nonce -- stays
// exactly as served).
// ---------------------------------------------------------------------------
const BOOTSTRAP = String.raw`
(function () {
  if (globalThis.__VT) return;
  var CAP = __CAP__;
  var buf = [];
  var total = 0;
  var depth = 0;
  var OPS = Object.prototype.toString;

  function tag(o) {
    try { return OPS.call(o); } catch (e) { return '<tag threw>'; }
  }

  // Enough of the answer to tell two engines apart, cheap enough to do a
  // hundred thousand times, and never the value itself for anything whose
  // stringification could run page code.
  function brief(v) {
    var t = typeof v;
    if (v === null) return 'null';
    if (t === 'undefined') return 'undefined';
    if (t === 'string') return v.length > 48 ? 's/' + v.length + '/' + v.slice(0, 48) : 's/' + v;
    if (t === 'number' || t === 'boolean' || t === 'bigint') return t.charAt(0) + '/' + String(v);
    if (t === 'symbol') return 'sym';
    if (t === 'function') {
      var n = '', a = '';
      try { n = String(v.name || ''); } catch (e) { n = '?'; }
      try { a = String(v.length); } catch (e) { a = '?'; }
      return 'fn/' + n + '/' + a;
    }
    return tag(v);
  }

  // The whole instrument. Called from the two branches of the VM's member
  // access opcode; must never throw and must read the property exactly once,
  // because a getter on the other side would run twice otherwise.
  globalThis.__vt = function (recv, name, receiverless) {
    if (receiverless) {
      total++;
      if (depth === 0 && buf.length < CAP) {
        depth++;
        try { buf.push('-|' + String(name) + '|(no receiver)'); } catch (e) { } finally { depth--; }
      }
      return name;
    }
    var v = recv[name];
    total++;
    if (depth === 0 && buf.length < CAP) {
      depth++;
      try { buf.push(tag(recv) + '|' + String(name) + '|' + brief(v)); } catch (e) { } finally { depth--; }
    }
    return v;
  };

  globalThis.__VT = {
    len: function () { return buf.length; },
    total: function () { return total; },
    slice: function (a, b) { return buf.slice(a, b); },
  };

  // Out over the console, because the realm that produces the trace is a
  // cross-origin child and a main-frame Runtime.evaluate cannot see it.
  // Grabbed before the page runs, so a bundle that replaces console.log later
  // does not take the channel with it. Timer-driven rather than end-of-run:
  // nothing outside the realm knows when the VM is finished.
  var origLog = console.log.bind(console);
  // Which realms got the bootstrap, and whether their console reaches the
  // driver at all. Without it, "the instrument never ran" and "the instrument
  // ran and the VM never reached an opcode" are the same empty result.
  try { origLog('@@VTHELLO@@' + (function () { try { return location.href; } catch (e) { return '?'; } })()); } catch (e) { }
  var sent = 0;
  function flush() {
    while (sent < buf.length) {
      var end = sent + 400 < buf.length ? sent + 400 : buf.length;
      try { origLog('@@VT@@' + sent + '@@' + JSON.stringify(buf.slice(sent, end)) + '@@END@@'); } catch (e) { }
      sent = end;
    }
  }
  try { setInterval(flush, 200); } catch (e) { }

  // Offline nobody starts the VM. The widget installs 25 globals -- one of them
  // named, unobfuscated, runProgram -- and then waits for the host page's
  // api.js to drive it over postMessage; with --reach every one of the 25 shows
  // a call count of zero. Rather than reimplement Turnstile's embed protocol,
  // the replay calls the entry point itself. Synthetic, but symmetric: both
  // engines enter the same function with the same document.
  var kick = __KICK__;
  if (kick) {
    setTimeout(function () {
      var fn;
      try { fn = globalThis[kick]; } catch (e) { }
      if (typeof fn !== 'function') {
        try { origLog('@@VTKICK@@absent:' + kick); } catch (e) { }
        return;
      }
      try {
        fn();
        try { origLog('@@VTKICK@@ok:' + kick); } catch (e) { }
      } catch (e) {
        try { origLog('@@VTKICK@@threw:' + kick + ':' + String(e && e.message || e)); } catch (x) { }
      }
    }, __KICK_MS__);
  }
})();
`;

// `--reach`. A trace of zero entries says the VM never ran; it does not say how
// far the bundle got before giving up, and the bundle logs nothing and throws
// nothing on the way. The globals it installs are the milestones it leaves
// behind -- 27 obfuscated names, all by plain assignment -- so this watches for
// new own properties of window, wraps the callable ones in a counter, and
// reports which of them anything ever called.
//
// Wrapping changes function identity, so it is a diagnostic and not something a
// measurement run should carry.
const REACH_SRC = String.raw`
(function () {
  var base = {};
  var names = Object.getOwnPropertyNames(globalThis);
  for (var i = 0; i < names.length; i++) base[names[i]] = 1;
  var seen = {};
  var calls = {};
  var kind = {};
  var firstArgs = {};
  var declared = {};
  var origLog = console.log.bind(console);

  function briefArg(v) {
    var t = typeof v;
    if (v === null) return 'null';
    if (t === 'string') return 'str(' + v.length + ')' + JSON.stringify(v.slice(0, 90));
    if (t === 'undefined' || t === 'number' || t === 'boolean') return String(v);
    if (t === 'function') return 'fn';
    try { return Object.prototype.toString.call(v) + JSON.stringify(Object.keys(v).slice(0, 12)); } catch (e) { return 'obj'; }
  }

  function scan() {
    var n = Object.getOwnPropertyNames(globalThis);
    for (var i = 0; i < n.length; i++) {
      var k = n[i];
      if (base[k] || seen[k]) continue;
      seen[k] = 1;
      var v;
      try { v = globalThis[k]; } catch (e) { kind[k] = 'threw'; continue; }
      kind[k] = typeof v;
      if (typeof v !== 'function') continue;
      calls[k] = 0;
      try {
        (function (key, fn) {
          globalThis[key] = function () {
            // The first call's arguments are how the offline replay learns to
            // start the VM the way the host page starts it.
            if (calls[key] === 0) {
              try {
                var a = [];
                for (var q = 0; q < arguments.length; q++) a.push(briefArg(arguments[q]));
                firstArgs[key] = a;
              } catch (e) { firstArgs[key] = ['<unreadable>']; }
            }
            // The widget declares globals by handing source text to its
            // trusted-types createScript wrapper. Whether the declaration then
            // *took* is the whole question behind the missing bGgjP8, and the
            // only honest way to answer it is to look right after the call
            // rather than to infer it from a scan that may have run too late.
            try {
              var a0 = arguments[0];
              if (typeof a0 === 'string') {
                var d = /^\s*function\s+([A-Za-z_$][\w$]*)\s*\(/.exec(a0);
                if (d && !declared[d[1]]) {
                  declared[d[1]] = 'pending via ' + key;
                  (function (dn, via) {
                    setTimeout(function () {
                      var t;
                      try { t = typeof globalThis[dn]; } catch (e) { t = 'threw'; }
                      declared[dn] = via + ' -> typeof window.' + dn + ' = ' + t;
                    }, 0);
                  })(d[1], key);
                }
              }
            } catch (e) { }
            calls[key]++;
            return fn.apply(this, arguments);
          };
        })(k, v);
      } catch (e) { kind[k] = 'function (unwrappable)'; }
    }
  }

  function report() {
    var out = [];
    for (var k in kind) {
      out.push(k + ':' + kind[k] + (calls[k] === undefined ? '' : '/' + calls[k])
        + (firstArgs[k] ? '  <- (' + firstArgs[k].join(', ') + ')' : ''));
    }
    try { origLog('@@VTREACH@@' + JSON.stringify({ realm: location.href, names: out, declared: declared }) + '@@END@@'); } catch (e) { }
  }

  scan();
  try { setInterval(scan, 25); } catch (e) { }
  try { setInterval(report, 1000); } catch (e) { }
})();
`;

// `--postmessage`. One record per message this realm receives, and -- with
// `--postmessage-sends` -- per message it sends to a window in its own realm or
// over a MessagePort. Origin, sender, payload kind and payload length, in
// arrival order, from every realm the bootstrap reached; see the header note for
// why the receiving side is the one that can be read.
//
// Nothing here touches delivery: the listener is registered before any page
// script, in the capture phase, and never stops propagation. The sends half
// replaces two functions and is behind its own flag for that reason.
const PM_SRC = String.raw`
(function () {
  if (globalThis.__PM) return;
  globalThis.__PM = 1;
  var CAP = 500;
  var SENDS = __PM_SENDS__;
  var origLog = console.log.bind(console);
  var seq = 0;
  var capped = false;

  // Which realm this is, said three ways, because no one way is enough. The
  // href repeats -- an interactive Turnstile runs a second document at the same
  // URL inside the first. Depth in the frame tree separates a nested widget
  // from its container; the random tag separates two realms at the same depth,
  // and is worthless under --determinize, where both realms draw the same first
  // number from the same fixed PRNG.
  //
  // The host's own executionContextId used to be worthless too -- this engine
  // reported the main frame's for every realm, so the census could only group
  // by the page-side tags. That is fixed (README, "Every realm answers with its
  // own execution context"): a parent and its child now come back as ctx 2 and
  // ctx 3 where both were ctx 2 before, which agrees with depth one for one.
  // The page-side tags stay because they are what makes that agreement
  // checkable, and because depth says something ctx does not -- where in the
  // tree the realm sits.
  //
  // No backticks anywhere in this comment, or in any other comment inside these
  // instrument sources: they are String.raw template literals, so a backtick
  // ends the template and the whole module stops parsing.
  var DEPTH = (function () {
    try {
      var d = 0, w = window;
      while (w !== w.parent && d < 20) { w = w.parent; d++; }
      return d;
    } catch (e) { return -1; }
  })();
  var RID = (function () {
    try { return Math.random().toString(36).slice(2, 8); } catch (e) { return '?'; }
  })();

  function say(rec) {
    if (seq >= CAP) {
      if (!capped) {
        capped = true;
        try { origLog('@@VTPM@@' + JSON.stringify({ dir: 'capped', at: CAP, realm: where() }) + '@@END@@'); } catch (e) { }
      }
      return;
    }
    rec.seq = seq++;
    rec.realm = where();
    rec.depth = DEPTH;
    rec.rid = RID;
    try { rec.kids = frames.length; } catch (e) { }
    try { origLog('@@VTPM@@' + JSON.stringify(rec) + '@@END@@'); } catch (e) { }
  }

  function where() {
    try { return location.href; } catch (e) { return '?'; }
  }

  // Kind and *length*, which is the whole comparison: the payloads are the same
  // ciphertext the wire carries, so what tells a passing conversation from a
  // stuck one is which messages exist and how big each is. Everything is
  // guarded -- a getter on a page object must not take the instrument down --
  // and the head of a string is kept short enough not to be a copy of it.
  function shape(v) {
    var t = typeof v;
    if (v === null) return { kind: 'null' };
    if (t === 'string') return { kind: 'string', len: v.length, head: v.slice(0, 64) };
    if (t === 'undefined' || t === 'number' || t === 'boolean' || t === 'bigint') return { kind: t, head: String(v) };
    if (t === 'function') return { kind: 'function' };
    try { if (v instanceof ArrayBuffer) return { kind: 'ArrayBuffer', len: v.byteLength }; } catch (e) { }
    try { if (globalThis.ArrayBuffer && ArrayBuffer.isView(v)) return { kind: 'view', len: v.byteLength }; } catch (e) { }
    var out = { kind: 'object' };
    try { out.keys = Object.keys(v).slice(0, 16); } catch (e) { }
    try { out.len = JSON.stringify(v).length; } catch (e) { out.len = -1; }
    // These payloads are named events -- {source, widgetId, event, seq} -- and
    // *which* event is missing is the question, so the short scalar fields are
    // kept by value. Anything past 48 characters is the ciphertext the wire
    // already carries and only its length is worth having.
    try {
      var vals = {};
      var ks = out.keys || [];
      for (var i = 0; i < ks.length; i++) {
        var x = v[ks[i]];
        var xt = typeof x;
        if (xt === 'string') vals[ks[i]] = x.length <= 48 ? x : 'len/' + x.length;
        else if (xt === 'number' || xt === 'boolean') vals[ks[i]] = x;
      }
      out.vals = vals;
    } catch (e) { }
    return out;
  }

  // Named the way the frame tree names it, because "which window" is the
  // question -- a message from the challenge iframe and one from an ad frame
  // are not the same event.
  function who(w) {
    if (w === null || w === undefined) return 'none';
    try { if (w === window) return 'self'; } catch (e) { }
    try { if (w === parent && parent !== window) return 'parent'; } catch (e) { }
    try { if (w === top && top !== window) return 'top'; } catch (e) { }
    try {
      var fs = document.getElementsByTagName('iframe');
      for (var i = 0; i < fs.length; i++) {
        try {
          if (fs[i].contentWindow === w) return 'iframe[' + i + '] ' + String(fs[i].getAttribute('src') || '').slice(0, 90);
        } catch (e) { }
      }
    } catch (e) { }
    return 'other';
  }

  try {
    addEventListener('message', function (e) {
      var rec = { dir: 'in' };
      try { rec.origin = e.origin; } catch (x) { rec.origin = '?'; }
      try { rec.from = who(e.source); } catch (x) { rec.from = '?'; }
      try { rec.ports = (e.ports && e.ports.length) || 0; } catch (x) { }
      try { rec.data = shape(e.data); } catch (x) { rec.data = { kind: '<unreadable>' }; }
      say(rec);
    }, true);
  } catch (e) {
    say({ dir: 'error', what: 'listener: ' + String((e && e.message) || e) });
  }

  if (SENDS) {
    var ownPost = null;
    try { ownPost = globalThis.postMessage; } catch (e) { }
    try {
      if (typeof ownPost === 'function') {
        Object.defineProperty(globalThis, 'postMessage', {
          configurable: true, writable: true,
          value: function (msg, target) {
            // The receiver matters: a same-origin sibling's postMessage
            // resolves to *its* global's own property, and forcing the call
            // onto this realm would redirect the message.
            var self = this || globalThis;
            say({ dir: 'out', to: who(self), target: String(target), data: shape(msg) });
            return ownPost.apply(self, arguments);
          },
        });
      }
    } catch (e) {
      say({ dir: 'error', what: 'own postMessage: ' + String((e && e.message) || e) });
    }
    try {
      var MP = globalThis.MessagePort && MessagePort.prototype;
      if (MP && typeof MP.postMessage === 'function') {
        var origPort = MP.postMessage;
        MP.postMessage = function (msg) {
          say({ dir: 'out-port', data: shape(msg) });
          return origPort.apply(this, arguments);
        };
      }
    } catch (e) {
      say({ dir: 'error', what: 'MessagePort.postMessage: ' + String((e && e.message) || e) });
    }
  }
})();
`;

// Same numbers on both engines, so a trace difference is a host difference and
// not the clock. Everything is guarded: this engine has no `performance` on
// some paths and no `crypto.getRandomValues` on others, and a throw here would
// abort the page before the bundle ever runs.
const DETERMINIZE_SRC = String.raw`
(function () {
  var t = 1787362297000;
  try { Date.now = function () { return (t += 17); }; } catch (e) { }
  try {
    var OD = Date;
    var D = function (a) {
      if (!(this instanceof D)) return new OD(t).toString();
      return arguments.length === 0 ? new OD(t) : new OD(a);
    };
    D.now = function () { return (t += 17); };
    D.parse = OD.parse; D.UTC = OD.UTC; D.prototype = OD.prototype;
    globalThis.Date = D;
  } catch (e) { }
  // A 32-bit xorshift, so both engines walk the same sequence.
  var s = 0x2f6e2b1;
  function next() { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s; }
  try { Math.random = function () { return next() / 4294967296; }; } catch (e) { }
  try {
    var p = 0;
    if (globalThis.performance) globalThis.performance.now = function () { return (p += 0.7); };
  } catch (e) { }
  try {
    if (globalThis.crypto) {
      globalThis.crypto.getRandomValues = function (a) {
        for (var i = 0; i < a.length; i++) a[i] = next();
        return a;
      };
    }
  } catch (e) { }
})();
`;

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

const raw = await fs.readFile(docPath, 'utf8');
const { patched, sites } = patch(raw);
if (sites.length === 0) {
    console.error(`no member-access opcode found in ${docPath} -- the obfuscator changed shape, re-derive OPCODE`);
    process.exit(3);
}

const state = {
    engine,
    doc: path.relative(REPO, docPath),
    docBytes: raw.length,
    settleMs: SETTLE,
    determinize: DETERMINIZE,
    topLevel: TOP_LEVEL,
    patchedSites: sites.map((s) => ({ offset: s.offset, text: s.text })),
    console: [],
    wire: [],
    exceptions: [],
    trace: [],
};

const widgetUrl = `http://127.0.0.1:${DOC_PORT}/widget.html`;
// Deliberately bare. Every element the widget needs it creates itself; adding
// a guessed container would be inventing context rather than supplying it, and
// what it actually reaches for is visible in the trace either way.
const PARENT_HTML = `<!DOCTYPE html><html><head><title>host</title></head><body>
<div id="host"><iframe id="w" src="${widgetUrl}" width="300" height="65" style="border:0"></iframe></div>
</body></html>`;

const serve = (port, body) => new Promise((resolve) => {
    const s = http.createServer((req, res) => {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        res.end(body);
    });
    s.listen(port, '127.0.0.1', () => resolve(s));
});

// `--url` drives the real interstitial instead of the replay. Nothing there is
// patched -- the document arrives from Cloudflare -- so the opcode trace stays
// empty and only the bootstrap's other instruments (notably --reach) report.
// That is the one way to see how the host page actually starts the widget.
const LIVE = arg('--url', null);
const servers = LIVE ? [] : [await serve(DOC_PORT, has('--no-patch') ? raw : patched)];
if (!LIVE && !TOP_LEVEL) servers.push(await serve(PARENT_PORT, PARENT_HTML));
const url = LIVE ?? (TOP_LEVEL ? widgetUrl : `http://127.0.0.1:${PARENT_PORT}/host.html`);
state.url = url;
state.live = LIVE !== null;

// The replay, held up for a different tool to drive. exception-frames.mjs
// already knows how to read a throw the page catches; pointing it at this URL
// beats growing a second copy of that machinery in here.
if (has('--serve')) {
    console.log(`serving ${url}${TOP_LEVEL ? '' : `  (widget at ${widgetUrl})`}`);
    console.log(has('--no-patch') ? 'unpatched' : `patched at ${sites.length} site(s)`);
    await new Promise(() => { });
}

// One source, installed into the page target and into every frame target that
// attaches, so a realm's readings do not depend on which process it landed in.
const attachFrames = has('--attach-frames');
// Asking for the sends half is asking for the instrument.
const PM_SENDS = has('--postmessage-sends');
const PM = PM_SENDS || has('--postmessage');
const bootstrapSrc = (DETERMINIZE ? DETERMINIZE_SRC : '')
    + BOOTSTRAP
        .replace('__CAP__', String(CAP))
        .replace('__KICK__', JSON.stringify(KICK))
        .replace('__KICK_MS__', String(KICK_MS))
    + (has('--reach') ? REACH_SRC : '')
    + (PM ? PM_SRC.replace('__PM_SENDS__', PM_SENDS ? 'true' : 'false') : '');
state.postMessage = PM ? (PM_SENDS ? 'in+out' : 'in') : 'off';

// startIndex -> entries, as they arrive over the console.
const chunks = new Map();
const engineLog = [];
let profile;
const proc = engine === 'chrome'
    ? spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-vmt-'))}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--window-size=1920,1080',
        // Chrome puts challenges.cloudflare.com in its own process, and an
        // out-of-process iframe's console does not reach the page session --
        // which reads as "Chrome recorded nothing" when in fact nothing was
        // listened to. Only for reading the child realm; it does change how
        // the reference browser is configured, so it stays behind a flag.
        //
        // Prefer `--attach-frames`. Turning site isolation off costs the
        // verdict: headed Chrome goes 5/5 to 0/3 on the same station with it
        // (README, results/e2/), so whatever the widget does under this flag is
        // what a *rejected* Chrome's widget does. Attaching to the iframe's own
        // target reads the same realm and leaves the browser alone.
        ...(has('--same-process')
            ? ['--disable-features=IsolateOrigins,site-per-process', '--disable-site-isolation-trials']
            : []),
        ...(has('--headed') ? [] : ['--headless=new']),
        ...chromeArgs,
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    : spawn(LIGHTPANDA, [
        'serve', '--host', '127.0.0.1', '--port', String(PORT),
        '--log_level', arg('--log-level', 'info'),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.on('data', (d) => engineLog.push(String(d)));
proc.stderr.on('data', (d) => engineLog.push(String(d)));
let exit = null;
proc.on('exit', (code, signal) => { exit = { code, signal }; });

let cdp;
try {
    for (let i = 0; i < 80; i++) {
        try {
            const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
            if (r.ok) { state.version = await r.json(); break; }
        } catch { /* not up yet */ }
        await sleep(250);
    }

    cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    cdp.on((msg) => {
        const p = msg.params ?? {};
        switch (msg.method) {
            // An out-of-process iframe is a target of its own, and it starts
            // paused so the instrument can be in place before its first inline
            // script runs -- which is the whole point here, since that script
            // is what installs the widget's globals. Enable, inject, release,
            // in that order; releasing early loses the realm.
            case 'Target.attachedToTarget': {
                if (!attachFrames || !p.sessionId) break;
                const child = p.sessionId;
                (state.frameSessions ??= []).push(p.targetInfo?.url?.slice(0, 140) ?? child);
                (async () => {
                    for (const domain of ['Runtime', 'Log', 'Network', 'Page']) {
                        await cdp.send(`${domain}.enable`, undefined, child).catch(() => { });
                    }
                    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: bootstrapSrc }, child)
                        .catch(() => { });
                    // Nested iframes are targets of the target, not of the page.
                    await cdp.send('Target.setAutoAttach',
                        { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, child).catch(() => { });
                    await cdp.send('Runtime.runIfWaitingForDebugger', undefined, child).catch(() => { });
                })();
                break;
            }
            case 'Runtime.consoleAPICalled': {
                const text = (p.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(' ');
                const hello = /^@@VTHELLO@@([\s\S]*)$/.exec(text);
                if (hello) {
                    (state.realms ??= []).push(hello[1]);
                    break;
                }
                const kick = /^@@VTKICK@@([\s\S]*)$/.exec(text);
                if (kick) { state.kick = kick[1]; break; }
                // Arrival order across realms is the only ordering there is:
                // each realm numbers its own records and no realm can see
                // another's, so `i` is what puts the conversation in sequence.
                const pm = /^@@VTPM@@([\s\S]*)@@END@@$/.exec(text);
                if (pm) {
                    try {
                        const rec = JSON.parse(pm[1]);
                        rec.i = (state.messages ??= []).length;
                        // Two realms can carry the same URL -- the widget is
                        // re-created on a retry -- so the realm a record came
                        // from is the host's execution context, not the href
                        // the page reports.
                        rec.ctx = p.executionContextId;
                        rec.ses = msg.sessionId ?? 'page';
                        state.messages.push(rec);
                    } catch {
                        state.messageErrors = (state.messageErrors ?? 0) + 1;
                    }
                    break;
                }
                const reach = /^@@VTREACH@@([\s\S]*)@@END@@$/.exec(text);
                if (reach) {
                    // Per realm, last report wins: the counters only grow.
                    try {
                        const r = JSON.parse(reach[1]);
                        (state.reach ??= {})[r.realm] = { names: r.names, declared: r.declared };
                    } catch { /* keep the previous one */ }
                    break;
                }
                const m = /^@@VT@@(\d+)@@([\s\S]*)@@END@@$/.exec(text);
                if (m) {
                    try {
                        chunks.set(Number(m[1]), JSON.parse(m[2]));
                    } catch (err) {
                        state.chunkErrors = (state.chunkErrors ?? 0) + 1;
                    }
                } else {
                    state.console.push(`${p.type}: ${text.slice(0, 300)}`);
                }
                break;
            }
            case 'Log.entryAdded':
                state.console.push(`log.${p.entry.level}: ${String(p.entry.text ?? '').slice(0, 300)}`);
                break;
            case 'Runtime.exceptionThrown':
                state.exceptions.push({
                    text: (p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 300),
                    line: (p.exceptionDetails?.lineNumber ?? -1) + 1,
                    col: (p.exceptionDetails?.columnNumber ?? -1) + 1,
                });
                break;
            case 'Network.requestWillBeSent':
                state.wire.push({ ev: 'req', url: String(p.request?.url ?? '').slice(0, 140), type: p.type });
                break;
            case 'Network.responseReceived':
                state.wire.push({ ev: 'res', status: p.response?.status, url: String(p.response?.url ?? '').slice(0, 140) });
                break;
            case 'Network.loadingFailed':
                state.wire.push({ ev: 'fail', text: p.errorText, url: String(p.request?.url ?? '').slice(0, 140) });
                break;
        }
    });

    for (const domain of ['Runtime', 'Log', 'Network', 'Page']) {
        await cdp.send(`${domain}.enable`, undefined, sessionId).catch(() => { });
    }

    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: bootstrapSrc }, sessionId)
        .catch((err) => { state.bootstrapError = String(err.message ?? err); });

    if (attachFrames) {
        await cdp.send('Target.setAutoAttach',
            { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId)
            .catch((err) => { state.attachError = String(err.message ?? err); });
    }

    await cdp.send('Page.navigate', { url }, sessionId);
    await sleep(SETTLE);
    // One more flush interval than the settle, so a chunk produced in the last
    // instant is not left in the page.
    await sleep(400);

    // Reassemble by start index. A missing chunk would silently shift every
    // entry after it, so the run stops at the first gap and says so rather
    // than handing the diff a trace whose indices no longer line up.
    const starts = [...chunks.keys()].sort((a, b) => a - b);
    let next = 0;
    for (const s of starts) {
        if (s !== next) { state.traceGapAt = next; break; }
        const part = chunks.get(s);
        state.trace.push(...part);
        next = s + part.length;
    }
    state.traceLen = state.trace.length;
    state.chunks = chunks.size;
} catch (err) {
    state.error = String(err.message ?? err);
} finally {
    cdp?.close();
    proc.kill('SIGKILL');
    for (const s of servers) s.close();
    if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

state.console = state.console.slice(-40);
// The wire is the frame the messages have to be read in -- which `fo/` POSTs
// happened, and whether the parent ever made its second one. A live challenge
// run makes well over forty requests, and the last forty of them are the tail
// of the widget's conversation with the last one cut off.
state.wire = state.wire.slice(-400);
state.engineLog = engineLog.join('').split('\n').filter(Boolean).slice(-30);
if (exit) state.engineExit = exit;

if (has('--keep')) {
    const p = resolveOut(`results/vm-trace-patched-${engine}.html`);
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, patched);
    console.log(`wrote ${path.relative(REPO, p)}`);
}

const out = arg('--out', null);
if (out) {
    const p = resolveOut(out);
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, `${JSON.stringify(state, null, 2)}\n`);
    console.log(`wrote ${path.relative(REPO, p)}`);
}

console.log(`\n${engine}  ${state.doc}`);
console.log(`url: ${url}   patched sites: ${sites.length}   determinize: ${DETERMINIZE}   kick: ${state.kick ?? (KICK ? 'no report' : 'off')}`);
console.log(`trace: ${state.trace.length} entries from ${state.chunks ?? 0} chunk(s)${state.traceGapAt === undefined ? '' : `, TRUNCATED at a missing chunk (index ${state.traceGapAt})`}`);
if (PM) printMessages();
if (state.error) console.log(`ERROR: ${state.error}`);
if (state.bootstrapError) console.log(`bootstrap not installed: ${state.bootstrapError}`);
for (const e of state.exceptions) console.log(`exception: ${e.text}  @${e.line}:${e.col}`);
for (const c of state.console.slice(-8)) console.log(`  ${c}`);
process.exit(0);

// ---------------------------------------------------------------------------
// postMessage summary
// ---------------------------------------------------------------------------

// One line per message, in arrival order, with the realm that recorded it. Long
// enough to read the conversation off the terminal; `--out` keeps the rest.
function printMessages() {
    const msgs = state.messages ?? [];
    if (msgs.length === 0) {
        console.log('messages: none recorded');
        return;
    }
    const realms = new Map();
    for (const m of msgs) {
        const k = `depth ${m.depth} ${m.rid} ctx ${m.ctx}  ${m.realm}`;
        realms.set(k, (realms.get(k) ?? 0) + 1);
    }
    console.log(`messages: ${msgs.length} across ${realms.size} realm(s)${state.messageErrors ? `, ${state.messageErrors} unparseable` : ''}`);
    for (const [realm, n] of realms) console.log(`  ${n.toString().padStart(4)}  ${realm.slice(0, 118)}`);
    const SHOW = 60;
    for (const m of msgs.slice(0, SHOW)) console.log(`  ${fmtMessage(m)}`);
    if (msgs.length > SHOW) console.log(`  … ${msgs.length - SHOW} more (only in --out)`);
}

function fmtMessage(m) {
    if (m.dir === 'capped') return `${String(m.i).padStart(3)}  CAPPED at ${m.at} in ${short(m.realm)}`;
    if (m.dir === 'error') return `${String(m.i).padStart(3)}  ERROR ${m.what} in ${short(m.realm)}`;
    const d = m.data ?? {};
    const size = d.len === undefined ? '' : ` len=${d.len}`;
    // The event name first, because that is what a message is called; the key
    // list only when there is no name to print.
    const ev = d.vals?.event ?? d.vals?.type ?? d.vals?.action;
    const keys = ev !== undefined
        ? ` ${ev}${d.vals?.seq === undefined ? '' : `#${d.vals.seq}`}`
        : d.keys?.length ? ` {${d.keys.join(',')}}` : '';
    // A port has neither a target window nor a target origin -- it is the
    // channel -- so those two columns are left off rather than printed empty.
    const peer = m.dir === 'in' ? `from ${m.from}` : m.dir === 'out' ? `to ${m.to ?? '?'}` : 'over a port';
    const org = m.dir === 'in' ? ` origin=${m.origin}` : m.dir === 'out' ? ` targetOrigin=${m.target}` : '';
    return `${String(m.i).padStart(3)}  ${m.dir.padEnd(8)} d${m.depth}/${m.rid} ${short(m.realm).padEnd(38)} ${peer}${org}  ${d.kind ?? '?'}${size}${keys}${m.ports ? ` ports=${m.ports}` : ''}`;
}

// A function declaration, not a const: printMessages runs above this point in
// the file and a const would still be in its temporal dead zone there.
function short(u) {
    return String(u ?? '?').replace(/^https?:\/\//, '').slice(0, 44);
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

async function diffMain() {
    const [, , , aPath, bPath] = process.argv;
    if (!aPath || !bPath) {
        console.error('usage: vm-trace.mjs diff <a.json> <b.json> [--window 8]');
        process.exit(2);
    }
    const W = Number(arg('--window', '8'));
    const a = JSON.parse(await fs.readFile(path.resolve(REPO, aPath), 'utf8'));
    const b = JSON.parse(await fs.readFile(path.resolve(REPO, bPath), 'utf8'));

    console.log(`A  ${a.engine}  ${a.trace.length} entries  doc ${a.doc}`);
    console.log(`B  ${b.engine}  ${b.trace.length} entries  doc ${b.doc}`);
    if (a.doc !== b.doc) console.log('WARNING: different documents -- the traces are not comparable');
    if (a.determinize !== b.determinize) console.log('WARNING: one side is not determinized');
    if (a.topLevel !== b.topLevel) console.log('WARNING: one side ran top-level and the other framed');
    for (const [who, s] of [['A', a], ['B', b]]) {
        if (s.traceGapAt !== undefined) console.log(`WARNING: ${who} is truncated at a missing chunk (index ${s.traceGapAt})`);
    }

    const n = Math.min(a.trace.length, b.trace.length);
    let at = -1;
    for (let i = 0; i < n; i++) {
        if (a.trace[i] !== b.trace[i]) { at = i; break; }
    }
    if (at < 0) {
        console.log(`\nidentical for the first ${n} entries; ${a.trace.length === b.trace.length
            ? 'and the same length -- no divergence in this run'
            : `then ${a.trace.length > b.trace.length ? 'A' : 'B'} keeps going (${Math.abs(a.trace.length - b.trace.length)} more)`}`);
        return;
    }

    console.log(`\nfirst divergence at entry ${at} of ${n}`);
    console.log(`\n  common prefix (last ${W}):`);
    for (let i = Math.max(0, at - W); i < at; i++) console.log(`    ${i}  ${a.trace[i]}`);
    console.log(`\n  A  ${a.trace[at]}`);
    console.log(`  B  ${b.trace[at]}`);
    console.log(`\n  A continues:`);
    for (let i = at + 1; i < Math.min(a.trace.length, at + 1 + W); i++) console.log(`    ${i}  ${a.trace[i]}`);
    console.log(`\n  B continues:`);
    for (let i = at + 1; i < Math.min(b.trace.length, at + 1 + W); i++) console.log(`    ${i}  ${b.trace[i]}`);
}
