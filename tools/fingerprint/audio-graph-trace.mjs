// Which audio graph does the widget actually build?
//
// It sends 1 000 `|`-joined floats and we send 1 000 zeros, because
// `canonical_render.matches()` (src/browser/webapi/audio/canonical_render.zig)
// refuses to replay the recorded render for a graph it does not recognise. Its
// predicates are exact double comparisons, so widening it needs the widget's
// numbers, not an approximation of them.
//
// audio-graph-solve.mjs got most of the way there without visiting the station,
// by searching real Chrome for the graph whose render is the oracle's: the tone
// is not 10 000 Hz but about 9 998.12, the compressor's ratio is at its clamp
// (Blink allows 1..20, fingerprintjs writes 12), release is near 0.257, and
// threshold, knee, attack and the triangle are fingerprintjs's. It stalls at a
// max residual of 4.8e-5 -- close enough to say *what kind* of graph it is and
// far enough to say the search is missing a structural piece, and in any case
// too approximate for a predicate that compares doubles.
//
// So watch the construction instead. Every funnel the graph has to pass through
// on its way to a render is wrapped, in the widget's own realm, ahead of its own
// code -- the same installation fo-plaintext.mjs uses and for the same reasons
// (fo-harness.mjs's header has them):
//
//   OfflineAudioContext / AudioContext   channels, length, sampleRate
//   BaseAudioContext.create*             every node, with an id
//   AudioNode.connect / disconnect       every edge, by id
//   AudioParam value / setValueAtTime    every parameter write, by node and name
//   OscillatorNode.type, start, stop     the source's own settings
//   startRendering                       and what the render came back as
//   AudioBuffer.getChannelData           which channel the widget reads
//
// The widget's audio realm is an iframe, not the blob worker (Web Audio is
// `Exposed=Window`, and p4b-oracle.json's vector does arrive from an iframe
// session), so the document-realm install is the one that matters here.
//
// usage:
//   node tools/fingerprint/audio-graph-trace.mjs <lightpanda|chrome>
//        [--headed-ua] [--url u] [--settle ms] [--out path] [--port n]
//        [--max-records n] [--samples n]
// env: LP_BIN, CHROME
import { arg, has, headedUserAgent, runTrace, writeRun } from './fo-harness.mjs';

const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: audio-graph-trace.mjs <lightpanda|chrome> [--headed-ua] [--out p]');
    process.exit(2);
}

const URL_ = arg('--url', 'https://www.scrapingcourse.com/cloudflare-challenge');
const SETTLE = Number(arg('--settle', '35000'));
const PORT = Number(arg('--port', engine === 'chrome' ? '9264' : '9265'));
const OUT = arg('--out', null);
// Audio records are a number and a name each, not a payload, so the budget can
// be far larger than fo-plaintext's without burying anything.
const MAX_RECORDS = Number(arg('--max-records', '4000'));
// How much of the render to bring back. Enough to check against the oracle's
// 1 000 and against chrome_audio_macos.bin, not so much that a console line
// stops being a reliable channel.
const SAMPLES = Number(arg('--samples', '1000'));
const headedUa = has('--headed-ua');

const MARK = '@@AUDIO@@';
const RECORDER = `(function () {
  var MARK = ${JSON.stringify(MARK)};
  var SAMPLES = ${SAMPLES};
  var n = 0;
  var log = console.log.bind(console);
  var stringify = JSON.stringify;
  // Recording is itself a stringify and a console.log; without this guard a
  // wrapper that fires during a record feeds itself.
  var inside = false;

  function emit(rec) {
    if (inside || n++ > ${MAX_RECORDS}) return;
    inside = true;
    try { log(MARK + stringify(rec)); } catch (e) { /* unserialisable */ }
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

  // Every node and context gets a name of its own, so an edge can be written
  // down as a pair of names rather than as two objects that do not serialise.
  var seq = 0;
  var ids = new WeakMap();
  function idOf(o, kind) {
    if (o === null || typeof o !== 'object') return String(o);
    var got = ids.get(o);
    if (!got) { got = (kind || 'obj') + (seq++); ids.set(o, got); }
    return got;
  }

  // Which node an AudioParam belongs to, and under what name. Blink hands the
  // same AudioParam object back on every read, so tagging once at creation is
  // enough and a later \`comp.threshold.value = -50\` resolves to a node and a
  // name rather than to an anonymous param.
  var params = new WeakMap();
  function tagParams(node, id) {
    try {
      for (var k in node) {
        var v;
        try { v = node[k]; } catch (e) { continue; }
        if (v && typeof v === 'object' && typeof globalThis.AudioParam === 'function'
            && v instanceof globalThis.AudioParam && !params.has(v)) {
          params.set(v, { node: id, name: k });
        }
      }
    } catch (e) { /* exotic node */ }
  }
  function whose(param) {
    var t = params.get(param);
    return t || { node: idOf(param, 'param'), name: '?' };
  }

  function wrap(owner, key, before) {
    if (!owner) return;
    var original;
    try { original = owner[key]; } catch (e) { return; }
    if (typeof original !== 'function') return;
    try {
      owner[key] = disguise(function () {
        var out = original.apply(this === undefined ? globalThis : this, arguments);
        try { before(this, arguments, out); } catch (e) { /* keep going */ }
        return out;
      }, original);
    } catch (e) { /* non-writable */ }
  }

  // An accessor rather than a method: \`osc.type = 'triangle'\` and
  // \`param.value = 10000\` are the two ways a fingerprint graph is configured
  // and neither passes through a function the page can see.
  function wrapSetter(proto, key, note) {
    if (!proto) return;
    var d;
    try { d = Object.getOwnPropertyDescriptor(proto, key); } catch (e) { return; }
    if (!d || !d.set) return;
    try {
      Object.defineProperty(proto, key, {
        configurable: true, enumerable: d.enumerable, get: d.get,
        set: function (v) { try { note(this, v); } catch (e) { /* keep going */ } return d.set.call(this, v); },
      });
    } catch (e) { /* frozen */ }
  }

  // --- contexts -------------------------------------------------------------
  // A Proxy rather than a hand-written function: it keeps the prototype, the
  // name, \`instanceof\` and toString() answering exactly as the original did.
  ['OfflineAudioContext', 'webkitOfflineAudioContext', 'AudioContext', 'webkitAudioContext'].forEach(function (name) {
    var Orig = globalThis[name];
    if (typeof Orig !== 'function') return;
    try {
      globalThis[name] = new Proxy(Orig, {
        construct: function (target, args) {
          var ctx = new target(...args);
          var id = idOf(ctx, 'ctx');
          var a = [];
          for (var i = 0; i < args.length; i++) {
            a.push(args[i] && typeof args[i] === 'object' ? stringify(args[i]) : args[i]);
          }
          var dest = null;
          try { dest = ctx.destination; } catch (e) { /* none */ }
          emit({ k: 'context', ctor: name, id: id, args: a,
                 sampleRate: ctx.sampleRate, length: ctx.length,
                 destination: dest ? idOf(dest, 'dest') : null,
                 destChannels: dest ? dest.channelCount : null,
                 destMode: dest ? dest.channelCountMode : null,
                 destInterp: dest ? dest.channelInterpretation : null });
          if (dest) tagParams(dest, idOf(dest, 'dest'));
          return ctx;
        },
      });
    } catch (e) { /* non-writable */ }
  });

  // --- factories ------------------------------------------------------------
  var Base = globalThis.BaseAudioContext && globalThis.BaseAudioContext.prototype;
  if (!Base && globalThis.AudioContext) Base = globalThis.AudioContext.prototype;
  ['createOscillator', 'createDynamicsCompressor', 'createGain', 'createBiquadFilter',
   'createAnalyser', 'createBuffer', 'createBufferSource', 'createDelay', 'createPanner',
   'createStereoPanner', 'createWaveShaper', 'createConvolver', 'createChannelSplitter',
   'createChannelMerger', 'createConstantSource', 'createIIRFilter', 'createPeriodicWave',
   'createScriptProcessor'].forEach(function (m) {
    wrap(Base, m, function (ctx, args, node) {
      var id = idOf(node, m.slice(6).toLowerCase());
      tagParams(node, id);
      var a = [];
      for (var i = 0; i < args.length; i++) if (typeof args[i] !== 'object') a.push(args[i]);
      emit({ k: 'create', m: m, id: id, ctx: idOf(ctx, 'ctx'), args: a,
             channelCount: node && node.channelCount, type: node && node.type });
    });
  });

  // --- edges ----------------------------------------------------------------
  var Node = globalThis.AudioNode && globalThis.AudioNode.prototype;
  ['connect', 'disconnect'].forEach(function (m) {
    wrap(Node, m, function (from, args) {
      var to = args[0];
      var isParam = to && typeof globalThis.AudioParam === 'function' && to instanceof globalThis.AudioParam;
      emit({ k: m, from: idOf(from, 'node'),
             to: to === undefined ? null : (isParam ? whose(to).node : idOf(to, 'node')),
             param: isParam ? whose(to).name : undefined,
             output: typeof args[1] === 'number' ? args[1] : undefined,
             input: typeof args[2] === 'number' ? args[2] : undefined });
    });
  });

  // --- parameters -----------------------------------------------------------
  wrapSetter(globalThis.AudioParam && globalThis.AudioParam.prototype, 'value', function (param, v) {
    var t = whose(param);
    emit({ k: 'param', node: t.node, name: t.name, v: v });
  });
  ['setValueAtTime', 'linearRampToValueAtTime', 'exponentialRampToValueAtTime',
   'setTargetAtTime', 'setValueCurveAtTime'].forEach(function (m) {
    wrap(globalThis.AudioParam && globalThis.AudioParam.prototype, m, function (param, args) {
      var t = whose(param);
      emit({ k: 'param', node: t.node, name: t.name, m: m,
             v: typeof args[0] === 'number' ? args[0] : String(args[0]),
             at: args[1], extra: args[2] });
    });
  });

  // --- the source -----------------------------------------------------------
  wrapSetter(globalThis.OscillatorNode && globalThis.OscillatorNode.prototype, 'type', function (osc, v) {
    emit({ k: 'oscType', node: idOf(osc, 'oscillator'), v: String(v) });
  });
  wrapSetter(globalThis.AudioBufferSourceNode && globalThis.AudioBufferSourceNode.prototype, 'buffer', function (src, b) {
    emit({ k: 'srcBuffer', node: idOf(src, 'buffersource'),
           length: b && b.length, sampleRate: b && b.sampleRate, channels: b && b.numberOfChannels });
  });
  ['channelCount', 'channelCountMode', 'channelInterpretation'].forEach(function (key) {
    wrapSetter(Node, key, function (node, v) {
      emit({ k: 'nodeProp', node: idOf(node, 'node'), name: key, v: String(v) });
    });
  });
  var Sched = globalThis.AudioScheduledSourceNode && globalThis.AudioScheduledSourceNode.prototype;
  ['start', 'stop'].forEach(function (m) {
    wrap(Sched, m, function (node, args) {
      emit({ k: m, node: idOf(node, 'node'), when: args.length ? args[0] : undefined });
    });
  });
  // AudioBufferSourceNode.start is Blink's own three-argument overload rather
  // than the inherited one, so wrapping only the base above sees an
  // oscillator's start and misses every buffer source's -- which is exactly the
  // node whose offset and duration decide what the render contains.
  var BufSrc = globalThis.AudioBufferSourceNode && globalThis.AudioBufferSourceNode.prototype;
  if (BufSrc && Object.prototype.hasOwnProperty.call(BufSrc, 'start')) {
    wrap(BufSrc, 'start', function (node, args) {
      emit({ k: 'start', node: idOf(node, 'buffersource'),
             when: args.length > 0 ? args[0] : undefined,
             offset: args.length > 1 ? args[1] : undefined,
             duration: args.length > 2 ? args[2] : undefined });
    });
  }
  ['loop', 'loopStart', 'loopEnd'].forEach(function (key) {
    wrapSetter(BufSrc, key, function (node, v) {
      emit({ k: 'nodeProp', node: idOf(node, 'buffersource'), name: key, v: String(v) });
    });
  });

  // --- the render -----------------------------------------------------------
  // The buffer itself, not a hash of it: the point of the trace is to be able
  // to check the graph it reports against the oracle's 1 000 floats, and only
  // the samples can do that.
  function describeBuffer(buf) {
    var out = { length: buf.length, sampleRate: buf.sampleRate, channels: buf.numberOfChannels };
    try {
      var d = buf.getChannelData(0);
      var lead = 0;
      while (lead < d.length && d[lead] === 0) lead++;
      out.leadingZeros = lead;
      var take = Math.min(SAMPLES, d.length);
      var s = [];
      for (var i = 0; i < take; i++) s.push(d[i]);
      out.samples = s.join('|');
    } catch (e) { out.err = String(e); }
    return out;
  }
  wrap(globalThis.OfflineAudioContext && globalThis.OfflineAudioContext.prototype, 'startRendering',
    function (ctx, args, promise) {
      emit({ k: 'startRendering', ctx: idOf(ctx, 'ctx'), sampleRate: ctx.sampleRate, length: ctx.length });
      try {
        promise.then(function (buf) {
          emit({ k: 'rendered', ctx: idOf(ctx, 'ctx'), buffer: describeBuffer(buf) });
        }, function () { emit({ k: 'renderFailed', ctx: idOf(ctx, 'ctx') }); });
      } catch (e) { /* not a promise on this engine */ }
    });
  wrap(globalThis.AudioBuffer && globalThis.AudioBuffer.prototype, 'getChannelData',
    function (buf, args) {
      emit({ k: 'getChannelData', buffer: idOf(buf, 'buffer'), channel: args[0], length: buf.length });
    });

  emit({ k: 'installed',
         href: String((globalThis.location || {}).href || '?').slice(0, 200),
         worker: typeof globalThis.WorkerGlobalScope !== 'undefined',
         offline: typeof globalThis.OfflineAudioContext,
         audio: typeof globalThis.AudioContext });
})();`;

const state = {
    engine, url: URL_, headedUa, settleMs: SETTLE, samples: SAMPLES,
    userAgentOverride: null,
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
});

// --- report -----------------------------------------------------------------
console.log(`=== ${engine}${headedUa ? ' --headed-ua' : ''} ===`);
console.log(`realms armed: ${state.realms.filter((r) => r.installed).length}/${state.realms.length}`);
const tally = new Map();
for (const r of state.records) tally.set(r.k, (tally.get(r.k) ?? 0) + 1);
console.log(`records: ${state.records.length}  ${[...tally].map(([k, v]) => `${k}=${v}`).join(' ')}`);

// The graph as it was built, in the order it was built, one line per record --
// which for a fingerprint graph is a dozen lines and reads like the source that
// produced it.
for (const r of state.records) {
    switch (r.k) {
        case 'context':
            console.log(`  ${r.ctor}(${r.args.join(', ')}) -> ${r.id}`
                + `  sampleRate=${r.sampleRate} length=${r.length}`
                + `  destination=${r.destination} channels=${r.destChannels}/${r.destMode}/${r.destInterp}`);
            break;
        case 'create':
            console.log(`  ${r.ctx}.${r.m}(${(r.args ?? []).join(', ')}) -> ${r.id}`
                + `  channelCount=${r.channelCount}${r.type !== undefined ? ` type=${r.type}` : ''}`);
            break;
        case 'param':
            console.log(`  ${r.node}.${r.name}${r.m ? `.${r.m}` : '.value'} = ${r.v}`
                + `${r.at !== undefined ? ` @${r.at}` : ''}`);
            break;
        case 'oscType': console.log(`  ${r.node}.type = ${JSON.stringify(r.v)}`); break;
        case 'nodeProp': console.log(`  ${r.node}.${r.name} = ${JSON.stringify(r.v)}`); break;
        case 'connect': case 'disconnect':
            console.log(`  ${r.from}.${r.k}(${r.to}${r.param ? `.${r.param}` : ''})`);
            break;
        // offset and duration are printed, not just recorded: they decide
        // which frames of a buffer reach the destination, and a summary line
        // reading `start(0)` for a call that skipped into the middle of the
        // buffer is how that argument goes unnoticed.
        case 'start': case 'stop': {
            const args = [r.when ?? '', r.offset, r.duration];
            while (args.length > 1 && args[args.length - 1] === undefined) args.pop();
            console.log(`  ${r.node}.${r.k}(${args.join(', ')})`);
            break;
        }
        case 'startRendering': console.log(`  ${r.ctx}.startRendering()  ${r.length} frames at ${r.sampleRate}`); break;
        case 'rendered': {
            const b = r.buffer ?? {};
            console.log(`  ${r.ctx} rendered ${b.length} frames at ${b.sampleRate},`
                + ` ${b.channels} channel(s), ${b.leadingZeros} leading zeros`);
            break;
        }
        case 'installed': console.log(`  installed ${r.href}  OfflineAudioContext=${r.offline}`); break;
        default: break;
    }
}
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
