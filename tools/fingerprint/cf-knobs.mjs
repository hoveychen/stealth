// Knobs for cf-knob.mjs. Each is a source string injected into every document,
// on every target, before anything on the page runs.
//
// The first three are controls and they earn their place. A knob that changes
// nothing and a knob that never ran look identical from the wire, so nothing
// here is interpretable until `alive` has been seen to report from BOTH
// documents -- the challenge page and the widget's cross-origin frame -- and
// until one knob has been seen to actually cost the ticket.
// A worker has no Image and no window, so both helpers have to answer without
// them -- the challenge runs two blob workers on challenges.cloudflare.com and
// a knob that throws on its first line inside one reports nothing at all.
// The channel is a global array, not a request.
//
// It used to be `new Image().src = '/__cfknob?...'`, which works from the
// challenge page and costs the ticket from the widget: `alive` -- one beacon
// and nothing else -- stopped the exchange at r1 twice in a row from
// challenges.cloudflare.com, with `none` holding its ticket 2/2 in the same
// window. One unexplained 404 inside its own frame is apparently enough. So
// nothing is sent; the harness reads this array off every session with
// Runtime.evaluate after the verdict is already on the wire.
// Every line carries its own sequence number, and that is not cosmetic. The
// harness drops a line it has already seen -- it re-reads a growing array, so
// it has to -- which silently collapsed a span the widget encoded three times
// into one. The wire channel used by the lightpanda arm keeps the repeats, so
// the two arms were being compared on their duplicate counts through two
// channels with opposite behaviour. With a counter in front, a repeat is a
// distinct line on both.
const beacon = `
  let __seq = 0;
  const __send = (q0) => {
    try {
      const g = globalThis;
      const q = 'n=' + (++__seq) + '&' + q0;
      (g.__cfk || (g.__cfk = [])).push(q);
      // --beacon. The stash is read back per SESSION, and this engine puts the
      // whole page in one target -- so the widget's frame, which has its own
      // global, is unreachable that way and its report is silently lost. On an
      // arm with no ticket to protect, a request is the honest channel.
      if (g.__CFK_WIRE) {
        if (typeof Image === 'function') { new Image().src = '/__cfknob?' + q; }
        else { fetch('/__cfknob?' + q, { mode: 'no-cors' }); }
      }
    } catch (e) {}
  };
  const __where = () => {
    try {
      if (typeof window === 'undefined') {
        return (self.location.origin || String(self.location.href).slice(0, 40)) + '/worker';
      }
      return location.host + (window.top === window ? '/top' : '/frame');
    } catch (e) { return 'cross-origin/frame'; }
  };
`;

export const CF_KNOBS = {
    // Control 1: nothing injected at all. The baseline the others are read
    // against -- if this loses the ticket, the station moved and no reading in
    // the session means anything.
    none: '',

    // Control 1b: the smallest possible injected script. `none` installs no
    // document script at all, so it cannot separate "the station judged what
    // the knob did" from "the station judged that a script was injected". This
    // one does nothing and still goes through
    // Page.addScriptToEvaluateOnNewDocument on every target, including the
    // widget's out-of-process frame.
    noop: ';',

    // Control 1c and 1d: the two things every reporting knob does, separated.
    //
    // `noop` keeps the ticket and `alive` -- helpers plus one recorded line --
    // loses it 4/4, so the cost is in the body, and the body only does two
    // things a page can see. `probe-lexical` declares globals the way an
    // injected script does; `probe-winprop` puts one own property on window.
    // Whichever loses the ticket is a constraint on every knob written after
    // it, because every reporting knob has to stash its answer somewhere.
    'probe-lexical': 'const __zzKnobA = 1; function __zzKnobB() { return __zzKnobA; }',
    'probe-winprop': 'try { globalThis.__cfk = []; } catch (e) {}',

    // Control 2: does the injection arrive, and where? Reports the host and
    // whether it is the top document, once per document. Until this shows the
    // widget's frame, a "still ticketed" reading only says the knob never ran.
    alive: beacon + `
      __send('alive=' + encodeURIComponent(__where()));
    `,

    // Control 3: the zero point. If this does NOT cost the ticket then the
    // oracle cannot read a refusal and every negative below is worthless. The
    // Kasada version of this knob costs Chrome its token 3 for 3.
    'webdriver-true': beacon + `
      __send('webdriver=' + encodeURIComponent(__where()));
      try {
        Object.defineProperty(Navigator.prototype, 'webdriver', {
          configurable: true, enumerable: true, get() { return true; },
        });
      } catch (e) { __send('webdriver-failed=' + e.name); }
    `,

    // From here down: one family each, all breaking a browser that otherwise
    // passes. Each reports that it installed, so a negative cannot be confused
    // with a knob that threw on the way in.

    // The console formatter this session implemented, turned back OFF in Chrome.
    // If the station weighs it, this is the knob that says so -- and it is the
    // direct test of whether the fix that closed 80% of the payload gap was
    // ever going to matter.
    'console-no-format': beacon + `
      __send('console-no-format=' + encodeURIComponent(__where()));
      try {
        for (const m of ['log','debug','info','warn','error','trace','group','groupCollapsed','assert']) {
          const real = console[m];
          if (typeof real !== 'function') continue;
          Object.defineProperty(console, m, {
            configurable: true, writable: true, enumerable: false,
            // Swallow every argument without converting any of it, which is
            // what this engine did before the formatter landed.
            value: function () { return undefined; },
          });
          void real;
        }
      } catch (e) { __send('console-failed=' + e.name); }
    `,

    // The control `console-no-format` needs, and without which it proves
    // nothing. It replaces the SAME methods through the SAME defineProperty
    // calls and then CALLS THE REAL ONE, so the conversion still happens and the
    // only thing that changed is that console is hooked. If this loses the
    // ticket too, the refusal is about the hooking and not about the
    // conversion -- the same trap `input-box-passthru` was built for on
    // x-hyatt.
    'console-passthru': beacon + `
      __send('console-passthru=' + encodeURIComponent(__where()));
      try {
        for (const m of ['log','debug','info','warn','error','trace','group','groupCollapsed','assert']) {
          const real = console[m];
          if (typeof real !== 'function') continue;
          Object.defineProperty(console, m, {
            configurable: true, writable: true, enumerable: false,
            value: function (...args) { return real.apply(console, args); },
          });
        }
      } catch (e) { __send('console-passthru-failed=' + e.name); }
    `,

    // And the narrowest version of the real question: keep every method native
    // and only stop the CONVERSION, by handing the guard a format string it
    // cannot use. Nothing about console is hooked here -- what changes is that
    // the first argument stops being a format string, so no specifier consumes
    // anything and nothing is converted.
    'console-defang-format': beacon + `
      __send('console-defang-format=' + encodeURIComponent(__where()));
      try {
        for (const m of ['log','debug','info','warn','error','trace']) {
          const real = console[m];
          if (typeof real !== 'function') continue;
          Object.defineProperty(console, m, {
            configurable: true, writable: true, enumerable: false,
            value: function (...args) {
              if (typeof args[0] === 'string' && args[0].indexOf('%') !== -1) {
                args[0] = args[0].split('%').join('\u0025\u200b');
              }
              return real.apply(console, args);
            },
          });
        }
      } catch (e) { __send('console-defang-failed=' + e.name); }
    `,

    // The whole console object replaced by plain functions -- a cruder version
    // of the above, in case the station probes the METHODS rather than their
    // argument handling.
    'console-plain': beacon + `
      __send('console-plain=' + encodeURIComponent(__where()));
      try {
        const plain = {};
        for (const k of Object.getOwnPropertyNames(console)) plain[k] = function () {};
        Object.defineProperty(window, 'console', {
          configurable: true, writable: true, enumerable: false, value: plain,
        });
      } catch (e) { __send('console-plain-failed=' + e.name); }
    `,

    // --- one family each, to find what the station weighs at all -------------
    //
    // These do not try to imitate this engine. They REMOVE a family from a
    // browser that otherwise passes, which answers "does Cloudflare weigh this
    // at all" -- and that is the cheap question, because a family it does not
    // weigh is a family this engine never has to match. Each reports that it
    // installed, so a kept ticket cannot be confused with a knob that threw.

    'no-error-stack': beacon + `
      __send('no-error-stack=' + encodeURIComponent(__where()));
      try {
        Object.defineProperty(Error.prototype, 'stack', {
          configurable: true, get() { return undefined; }, set() {},
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'native-tostring': beacon + `
      __send('native-tostring=' + encodeURIComponent(__where()));
      try {
        const real = Function.prototype.toString;
        Object.defineProperty(Function.prototype, 'toString', {
          configurable: true, writable: true, enumerable: false,
          value: function () {
            const s = real.call(this);
            return s.indexOf('[native code]') === -1 ? s : 'function () { /* nope */ }';
          },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'no-canvas-readback': beacon + `
      __send('no-canvas-readback=' + encodeURIComponent(__where()));
      try {
        const blank = 'data:,';
        Object.defineProperty(HTMLCanvasElement.prototype, 'toDataURL', {
          configurable: true, writable: true, enumerable: false,
          value: function () { return blank; },
        });
        const ctxProto = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
        if (ctxProto) {
          Object.defineProperty(ctxProto, 'getImageData', {
            configurable: true, writable: true, enumerable: false,
            value: function (x, y, w, h) { return new ImageData(Math.max(1, w | 0), Math.max(1, h | 0)); },
          });
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    'no-webgl': beacon + `
      __send('no-webgl=' + encodeURIComponent(__where()));
      try {
        const real = HTMLCanvasElement.prototype.getContext;
        Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
          configurable: true, writable: true, enumerable: false,
          value: function (kind, ...rest) {
            if (typeof kind === 'string' && kind.indexOf('webgl') !== -1) return null;
            return real.call(this, kind, ...rest);
          },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'no-plugins': beacon + `
      __send('no-plugins=' + encodeURIComponent(__where()));
      try {
        Object.defineProperty(Navigator.prototype, 'plugins', {
          configurable: true, enumerable: true, get() { return Object.create(PluginArray.prototype); },
        });
        Object.defineProperty(Navigator.prototype, 'mimeTypes', {
          configurable: true, enumerable: true, get() { return Object.create(MimeTypeArray.prototype); },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'no-timezone': beacon + `
      __send('no-timezone=' + encodeURIComponent(__where()));
      try {
        const real = Intl.DateTimeFormat.prototype.resolvedOptions;
        Object.defineProperty(Intl.DateTimeFormat.prototype, 'resolvedOptions', {
          configurable: true, writable: true, enumerable: false,
          value: function () {
            const o = real.call(this);
            o.timeZone = 'Olympus Mons Time';
            return o;
          },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'coarse-performance': beacon + `
      __send('coarse-performance=' + encodeURIComponent(__where()));
      try {
        const real = Performance.prototype.now;
        Object.defineProperty(Performance.prototype, 'now', {
          configurable: true, writable: true, enumerable: false,
          value: function () { return Math.floor(real.call(this) / 100) * 100; },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    'detached-computed-values': beacon + `
      __send('detached-computed-values=' + encodeURIComponent(__where()));
      try {
        // Chrome answers the empty string for every property of a DETACHED
        // element; this engine answers values. This hands Chrome our shape, so
        // the knob says whether the station reads a detached element at all.
        const real = window.getComputedStyle;
        Object.defineProperty(window, 'getComputedStyle', {
          configurable: true, writable: true, enumerable: false,
          value: function (el, pseudo) {
            const cs = real.call(window, el, pseudo);
            try { if (el && el.isConnected === false) return real.call(window, document.body, pseudo); }
            catch (e) { /* fall through */ }
            return cs;
          },
        });
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The two names the widget reads and this engine does not have.
    //
    // Diffing the widget's own ninety-name read list between the arms leaves
    // exactly two real differences once the harness's geometry is matched:
    // `window.documentPictureInPicture` and `window.sharedStorage`. Both are
    // present in Chrome 151 and absent here, and both are read by the document
    // that builds the payload. This deletes them from a Chrome that otherwise
    // passes, which is the only way to learn whether their absence is weighed
    // or merely noticed.
    'no-newer-globals': beacon + `
      __send('no-newer-globals=' + encodeURIComponent(__where()));
      try {
        const gone = [];
        for (const n of ['documentPictureInPicture', 'sharedStorage']) {
          if (!(n in window)) { gone.push(n + ':already-absent'); continue; }
          try {
            delete window[n];
            gone.push(n + ':' + (n in window ? 'still-there' : 'deleted'));
          } catch (e) { gone.push(n + ':' + e.name); }
        }
        __send('deleted=' + encodeURIComponent(gone.join(' ')) + '&at=' + encodeURIComponent(__where()));
      } catch (e) { __send('fail=' + e.name); }
    `,

    // Two answers the widget asks for and gets a different one from here.
    //
    // `report-calls` on both arms shows the same calls in the same places. Two
    // of the answers differ: Chrome hands back about fifty voices where this
    // engine hands back an empty list, and Chrome's performance.memory stays
    // near a megabyte across four samples where this engine climbs from 3MB to
    // 82MB across ten. These give Chrome this engine's answer, one at a time.
    'empty-voices': beacon + `
      __send('empty-voices=' + encodeURIComponent(__where()));
      try {
        const proto = window.SpeechSynthesis && SpeechSynthesis.prototype;
        if (!proto) { __send('no-SpeechSynthesis&at=' + encodeURIComponent(__where())); }
        else {
          Object.defineProperty(proto, 'getVoices', {
            configurable: true, writable: true, enumerable: false,
            value: function () { return []; },
          });
          __send('voices-emptied&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    'growing-heap': beacon + `
      __send('growing-heap=' + encodeURIComponent(__where()));
      try {
        const p = window.performance;
        const m = p && p.memory;
        if (!m) { __send('no-memory&at=' + encodeURIComponent(__where())); }
        else {
          // This engine's measured shape: same limit, an order of magnitude
          // more heap, and climbing between samples instead of flat.
          let total = 3145728, used = 2421464;
          Object.defineProperty(p, 'memory', {
            configurable: true, enumerable: true,
            get() {
              total = Math.min(total * 2, 82362368);
              used = Math.floor(total * 0.72);
              return { jsHeapSizeLimit: 4395630592, totalJSHeapSize: total, usedJSHeapSize: used };
            },
          });
          __send('heap-replaced&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The control `growing-heap` needs, and without which it proves nothing.
    //
    // It replaces the SAME property through the SAME defineProperty call and
    // hands back the REAL MemoryInfo, so the only thing that changed is that
    // the property is an own accessor rather than a prototype one. If this
    // loses the ticket too, the refusal is about the hook -- a plain object
    // where a MemoryInfo belongs, or an accessor that is not native -- and not
    // about the numbers. Same trap console-passthru was built for.
    'heap-passthru': beacon + `
      __send('heap-passthru=' + encodeURIComponent(__where()));
      try {
        const p = window.performance;
        const m = p && p.memory;
        if (!m) { __send('no-memory&at=' + encodeURIComponent(__where())); }
        else {
          Object.defineProperty(p, 'memory', {
            configurable: true, enumerable: true, get() { return m; },
          });
          __send('heap-passthru-installed&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    // And the narrowest version of the real question, if the control says the
    // hook is free: keep Chrome's own MemoryInfo object and only make the
    // numbers this engine's. Not possible through the instance -- MemoryInfo's
    // accessors live on its prototype -- so the prototype is where this goes,
    // which leaves the object's brand and identity alone.
    'heap-numbers-only': beacon + `
      __send('heap-numbers-only=' + encodeURIComponent(__where()));
      try {
        const m = window.performance && performance.memory;
        const proto = m && Object.getPrototypeOf(m);
        if (!proto) { __send('no-memory-proto&at=' + encodeURIComponent(__where())); }
        else {
          let total = 3145728;
          Object.defineProperty(proto, 'totalJSHeapSize', {
            configurable: true, enumerable: true,
            get() { total = Math.min(total * 2, 82362368); return total; },
          });
          Object.defineProperty(proto, 'usedJSHeapSize', {
            configurable: true, enumerable: true,
            get() { return Math.floor(total * 0.72); },
          });
          __send('heap-numbers-installed&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    // Give Chrome this engine's worker failure.
    //
    // report-workers on both arms, inside the widget's own frame: the challenge
    // makes a 13-byte blob worker and then a 291-byte one. In Chrome both start
    // and the second answers. Here the 13-byte one fires `error` with message
    // "Abort" -- it never runs -- and the challenge goes on to build a THIRD
    // worker that Chrome never builds. That is a structural difference in the
    // document that assembles the payload, so this reproduces it on the arm
    // that passes: the first Worker gets a URL that cannot load, which is what
    // an aborted worker looks like from the page.
    'first-worker-aborts': beacon + `
      (() => {
        __send('first-worker-aborts=' + encodeURIComponent(__where()));
        try {
          const Real = window.Worker;
          if (typeof Real !== 'function') { __send('no-Worker'); return; }
          let n = 0;
          const Hooked = new Proxy(Real, {
            construct(target, args, nt) {
              n += 1;
              if (n === 1) {
                const dead = URL.createObjectURL(new Blob([';'], { type: 'text/javascript' }));
                URL.revokeObjectURL(dead);
                __send('aborting-worker=1&at=' + encodeURIComponent(__where()));
                return Reflect.construct(target, [dead, args[1]], nt);
              }
              return Reflect.construct(target, args, nt);
            },
          });
          Object.defineProperty(window, 'Worker', {
            configurable: true, writable: true, enumerable: false, value: Hooked,
          });
          __send('worker-hooked&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('fail=' + e.name); }
      })();
    `,

    // The control it needs: the same Proxy on the same constructor, forwarding
    // every construction untouched. If this loses the ticket, the refusal is
    // about hooking Worker and says nothing about the abort. heap-passthru is
    // why this is not optional -- it cost two knobs their meaning.
    'worker-passthru': beacon + `
      (() => {
        __send('worker-passthru=' + encodeURIComponent(__where()));
        try {
          const Real = window.Worker;
          if (typeof Real !== 'function') { __send('no-Worker'); return; }
          const Hooked = new Proxy(Real, {
            construct(target, args, nt) { return Reflect.construct(target, args, nt); },
          });
          Object.defineProperty(window, 'Worker', {
            configurable: true, writable: true, enumerable: false, value: Hooked,
          });
          __send('worker-passthru-hooked&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('fail=' + e.name); }
      })();
    `,

    // The r3 payload, before it is enciphered.
    //
    // r3 is ~90KB of a custom alphabet and the two arms answer it differently;
    // deobfuscating it is not the move (memory: payload-bytes-by-lengthening).
    // The move is the one that worked on Kasada -- hook the plaintext on its
    // way into the encoder -- and it only became possible once the harness
    // could script the widget's own frame, which is where the encoding happens.
    //
    // Records length and a cheap hash rather than content, because the content
    // is the fingerprint and the point is to find WHICH span differs.
    'report-payload': beacon + `
      (() => {
        const hash = (s) => {
          let h = 5381;
          for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
          return h.toString(36);
        };
        const note = (what, s) => {
          try {
            const str = typeof s === 'string' ? s : String(s);
            if (str.length < 64) return;
            // Short spans come back whole. The font list is one of them, and
            // its 90-character prefix says only that the two arms disagree,
            // not which names this engine adds.
            const head = str.length <= 1200 ? str : str.slice(0, 90);
            __send('span=' + encodeURIComponent(what) + '&len=' + str.length +
                   '&h=' + hash(str) + '&head=' + encodeURIComponent(head) +
                   '&at=' + encodeURIComponent(__where()));
          } catch (e) {}
        };
        try {
          const realStringify = JSON.stringify;
          JSON.stringify = function (...a) {
            const r = realStringify.apply(JSON, a);
            note('JSON.stringify', r);
            return r;
          };
        } catch (e) { __send('stringify-hook-failed=' + e.name); }
        try {
          const realEncode = TextEncoder.prototype.encode;
          Object.defineProperty(TextEncoder.prototype, 'encode', {
            configurable: true, writable: true, enumerable: false,
            value: function (s) { note('TextEncoder.encode', s); return realEncode.call(this, s); },
          });
        } catch (e) { __send('encode-hook-failed=' + e.name); }
        try {
          const realSend = XMLHttpRequest.prototype.send;
          Object.defineProperty(XMLHttpRequest.prototype, 'send', {
            configurable: true, writable: true, enumerable: false,
            value: function (body) { note('xhr.send', body); return realSend.call(this, body); },
          });
        } catch (e) { __send('xhr-hook-failed=' + e.name); }
        try {
          const realFetch = window.fetch;
          Object.defineProperty(window, 'fetch', {
            configurable: true, writable: true, enumerable: false,
            value: function (input, init) {
              if (init && init.body) note('fetch.body', init.body);
              return realFetch.call(window, input, init);
            },
          });
        } catch (e) { __send('fetch-hook-failed=' + e.name); }
        __send('report-payload=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // How does the widget decide a font is installed?
    //
    // report-payload catches the answer -- six names in Chrome, fifty-four
    // here, including Windows and GNOME families that no Mac has. Guessing the
    // mechanism did not work: span width, canvas measureText, every TextMetrics
    // field, document.fonts.check and queryLocalFonts all agree between the
    // arms. So this records the measurement calls themselves, with the family
    // that was in play and the number that came back, and the disagreement has
    // to be in there.
    'report-font-probe': beacon + `
      (() => {
        const seen = Object.create(null);
        const rec = (s) => {
          const k = String(s).slice(0, 120);
          if (seen[k]) { seen[k] += 1; return; }
          seen[k] = 1;
          __send('probe=' + encodeURIComponent(k) + '&at=' + encodeURIComponent(__where()));
        };
        const fam = (el) => {
          try {
            const inline = el.style && el.style.fontFamily;
            if (inline) return inline.slice(0, 40);
            return '(' + (el.tagName || '?') + ')';
          } catch (e) { return '?'; }
        };
        const wrapGetter = (proto, name, label) => {
          try {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.get) { rec(label + ':no-getter'); return; }
            const g = d.get;
            Object.defineProperty(proto, name, {
              configurable: true, enumerable: d.enumerable,
              get() { const v = g.call(this); rec(label + ' ' + fam(this) + ' => ' + v); return v; },
            });
          } catch (e) { rec(label + ':hook-failed:' + e.name); }
        };
        wrapGetter(HTMLElement.prototype, 'offsetWidth', 'offsetWidth');
        wrapGetter(HTMLElement.prototype, 'offsetHeight', 'offsetHeight');
        try {
          const real = Element.prototype.getBoundingClientRect;
          Object.defineProperty(Element.prototype, 'getBoundingClientRect', {
            configurable: true, writable: true, enumerable: false,
            value: function () {
              const r = real.call(this);
              rec('rect ' + fam(this) + ' => ' + Math.round(r.width * 100) / 100 + 'x' + Math.round(r.height * 100) / 100);
              return r;
            },
          });
        } catch (e) { rec('rect:hook-failed:' + e.name); }
        try {
          const real = CanvasRenderingContext2D.prototype.measureText;
          Object.defineProperty(CanvasRenderingContext2D.prototype, 'measureText', {
            configurable: true, writable: true, enumerable: false,
            value: function (t) {
              const m = real.call(this, t);
              rec('measureText ' + String(this.font).slice(0, 40) + ' => ' + Math.round(m.width * 100) / 100);
              return m;
            },
          });
        } catch (e) { rec('measureText:hook-failed:' + e.name); }
        try {
          const fs = document.fonts;
          const real = fs.check;
          fs.check = function (...a) {
            const r = real.apply(fs, a);
            rec('fonts.check ' + String(a[0]).slice(0, 40) + ' => ' + r);
            return r;
          };
        } catch (e) { rec('fonts.check:hook-failed:' + e.name); }
        // The ones the first pass missed, and one of them has to be it: an
        // OffscreenCanvas context is a different prototype from a canvas one,
        // a Range measures text without an element, and scrollWidth/clientWidth
        // are two more ways to read a box.
        try {
          const p = window.OffscreenCanvasRenderingContext2D &&
            OffscreenCanvasRenderingContext2D.prototype;
          if (!p) { rec('offscreen:absent'); }
          else {
            const real = p.measureText;
            Object.defineProperty(p, 'measureText', {
              configurable: true, writable: true, enumerable: false,
              value: function (t) {
                const m = real.call(this, t);
                rec('offscreen.measureText ' + String(this.font).slice(0, 40) +
                    ' => ' + Math.round(m.width * 100) / 100);
                return m;
              },
            });
          }
        } catch (e) { rec('offscreen:hook-failed:' + e.name); }
        wrapGetter(Element.prototype, 'scrollWidth', 'scrollWidth');
        wrapGetter(Element.prototype, 'clientWidth', 'clientWidth');
        try {
          const real = Range.prototype.getBoundingClientRect;
          Object.defineProperty(Range.prototype, 'getBoundingClientRect', {
            configurable: true, writable: true, enumerable: false,
            value: function () {
              const r = real.call(this);
              rec('range.rect => ' + Math.round(r.width * 100) / 100 + 'x' + Math.round(r.height * 100) / 100);
              return r;
            },
          });
        } catch (e) { rec('range:hook-failed:' + e.name); }
        // And the producer itself: the list arrives on the wire as names joined
        // by a pipe, so whatever built it called join once with that separator.
        try {
          const realJoin = Array.prototype.join;
          Object.defineProperty(Array.prototype, 'join', {
            configurable: true, writable: true, enumerable: false,
            value: function (sep) {
              const r = realJoin.call(this, sep);
              if (sep === '|' && r.length > 40 && r.length < 2000) {
                let where = '';
                try { where = String(new Error().stack || '').split('\\n').slice(1, 4).join(' <- '); }
                catch (e) { where = 'no-stack'; }
                rec('join| n=' + this.length + ' len=' + r.length + ' at ' + where.slice(0, 200));
              }
              return r;
            },
          });
        } catch (e) { rec('join:hook-failed:' + e.name); }
        __send('report-font-probe=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // Which call produces each pixel buffer, and which one produces nothing?
    //
    // With the poll fixed, the widget's span list is comparable for the first
    // time, and the arms differ in exactly one structural way: Chrome encodes a
    // 4096-byte buffer (1024 opaque-black pixels, so 32x32 RGBA) that this
    // engine never encodes at all. Every other span is present on both sides,
    // in the same multiplicity. A span whose value differs has been shown four
    // times over not to matter; a span that is absent is a different claim --
    // it says a measurement did not happen. This records every call that can
    // hand back pixels, with its size and the shape of what came back, so the
    // missing 4096 can be attributed to a call rather than guessed at.
    'report-pixels': beacon + `
      (() => {
        const hash = (s) => {
          let h = 5381;
          for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
          return h.toString(36);
        };
        const shape = (v) => {
          try {
            if (!v) return String(v);
            if (typeof v.length === 'number') {
              let s = '';
              const n = Math.min(v.length, 4096);
              for (let i = 0; i < n; i++) s += String.fromCharCode(v[i] & 255);
              return 'len=' + v.length + ' h=' + hash(s);
            }
            return typeof v;
          } catch (e) { return 'shape-threw'; }
        };
        const rec = (s) => __send('px=' + encodeURIComponent(String(s).slice(0, 300)) +
                                  '&at=' + encodeURIComponent(__where()));
        const wrap = (proto, name, label, describe) => {
          try {
            if (!proto || !proto[name]) { rec(label + ':absent'); return; }
            const real = proto[name];
            Object.defineProperty(proto, name, {
              configurable: true, writable: true, enumerable: false,
              value: function (...a) {
                let r, err = null;
                try { r = real.apply(this, a); } catch (e) { err = e; }
                try { rec(label + ' ' + describe(this, a, r, err)); } catch (e) {}
                if (err) throw err;
                return r;
              },
            });
          } catch (e) { rec(label + ':hook-failed:' + e.name); }
        };
        const cv = (c) => { try { return (c.width || '?') + 'x' + (c.height || '?'); } catch (e) { return '?'; } };

        wrap(HTMLCanvasElement.prototype, 'getContext', 'canvas.getContext',
             (t, a, r, e) => a[0] + ' canvas=' + cv(t) + ' => ' + (e ? 'THREW:' + e.name : r ? 'ok' : String(r)));
        wrap(HTMLCanvasElement.prototype, 'toDataURL', 'canvas.toDataURL',
             (t, a, r, e) => 'canvas=' + cv(t) + ' => ' + (e ? 'THREW:' + e.name : 'len=' + String(r).length + ' h=' + hash(String(r))));
        wrap(CanvasRenderingContext2D.prototype, 'getImageData', 'ctx.getImageData',
             (t, a, r, e) => a.slice(0, 4).join(',') + ' canvas=' + cv(t.canvas || {}) +
                             ' => ' + (e ? 'THREW:' + e.name : shape(r && r.data)));
        if (typeof WebGLRenderingContext === 'function') {
          wrap(WebGLRenderingContext.prototype, 'readPixels', 'gl.readPixels',
               (t, a, r, e) => a.slice(0, 4).join(',') + ' => ' + (e ? 'THREW:' + e.name : shape(a[6])));
        } else { rec('WebGLRenderingContext:absent'); }
        if (typeof WebGL2RenderingContext === 'function') {
          wrap(WebGL2RenderingContext.prototype, 'readPixels', 'gl2.readPixels',
               (t, a, r, e) => a.slice(0, 4).join(',') + ' => ' + (e ? 'THREW:' + e.name : shape(a[6])));
        } else { rec('WebGL2RenderingContext:absent'); }
        if (typeof OffscreenCanvas === 'function') {
          wrap(OffscreenCanvas.prototype, 'getContext', 'offscreen.getContext',
               (t, a, r, e) => a[0] + ' canvas=' + cv(t) + ' => ' + (e ? 'THREW:' + e.name : r ? 'ok' : String(r)));
          wrap(OffscreenCanvas.prototype, 'convertToBlob', 'offscreen.convertToBlob',
               (t, a, r, e) => 'canvas=' + cv(t) + ' => ' + (e ? 'THREW:' + e.name : 'promise'));
          wrap(OffscreenCanvas.prototype, 'transferToImageBitmap', 'offscreen.transferToImageBitmap',
               (t, a, r, e) => 'canvas=' + cv(t) + ' => ' + (e ? 'THREW:' + e.name : r ? r.width + 'x' + r.height : String(r)));
        } else { rec('OffscreenCanvas:absent'); }
        // An offscreen 2d context is NOT a CanvasRenderingContext2D, so the
        // readback that produced the 8624-byte span went unrecorded until this.
        if (typeof OffscreenCanvasRenderingContext2D === 'function') {
          wrap(OffscreenCanvasRenderingContext2D.prototype, 'getImageData', 'offctx.getImageData',
               (t, a, r, e) => a.slice(0, 4).join(',') + ' canvas=' + cv(t.canvas || {}) +
                               ' => ' + (e ? 'THREW:' + e.name : shape(r && r.data)));
          wrap(OffscreenCanvasRenderingContext2D.prototype, 'drawImage', 'offctx.drawImage',
               (t, a, r, e) => (a[0] && a[0].constructor ? a[0].constructor.name : typeof a[0]) +
                               ' args=' + (a.length - 1) + ' canvas=' + cv(t.canvas || {}) +
                               ' => ' + (e ? 'THREW:' + e.name : 'ok'));
        } else { rec('OffscreenCanvasRenderingContext2D:absent'); }
        try {
          if (typeof ImageData === 'function') {
            const RealImageData = ImageData;
            const Shim = function (...a) {
              const r = new RealImageData(...a);
              try { rec('new ImageData ' + a.map((x) => (x && x.length) || x).join(',') + ' => ' + r.width + 'x' + r.height); } catch (e) {}
              return r;
            };
            Shim.prototype = RealImageData.prototype;
            globalThis.ImageData = Shim;
          } else { rec('ImageData:absent'); }
        } catch (e) { rec('ImageData:hook-failed:' + e.name); }
        try {
          if (typeof createImageBitmap === 'function') {
            const real = createImageBitmap;
            globalThis.createImageBitmap = function (...a) {
              const label = 'createImageBitmap ' + (a[0] && a[0].constructor ? a[0].constructor.name : typeof a[0]);
              let p;
              try { p = real.apply(globalThis, a); } catch (e) { rec(label + ' => THREW:' + e.name); throw e; }
              return p.then((b) => { rec(label + ' => ' + (b ? b.width + 'x' + b.height : String(b))); return b; },
                            (e) => { rec(label + ' => REJECTED:' + (e && e.name)); throw e; });
            };
          } else { rec('createImageBitmap:absent'); }
        } catch (e) { rec('createImageBitmap:hook-failed:' + e.name); }
        __send('report-pixels=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // Does the widget get pixels out of WebGPU, and do we?
    //
    // report-pixels accounts for every buffer the widget encodes except one:
    // Chrome encodes 4096 bytes of opaque black -- 1024 pixels, so 32x32 RGBA --
    // and no canvas or WebGL call in the recording produces it. The one pixel
    // source left in the list is getContext('webgpu'), which BOTH arms answer
    // with a live object. If the readback happens through WebGPU on Chrome and
    // dies somewhere in the middle here, the arms differ by a measurement that
    // did not happen rather than by a value, which is the one shape of
    // difference this door has not been tested against.
    'report-gpu': beacon + `
      (() => {
        const rec = (s) => __send('gpu=' + encodeURIComponent(String(s).slice(0, 300)) +
                                  '&at=' + encodeURIComponent(__where()));
        const wrap = (proto, name, label, describe) => {
          try {
            if (!proto) { rec(label + ':no-proto'); return; }
            if (!proto[name]) { rec(label + ':absent'); return; }
            const real = proto[name];
            Object.defineProperty(proto, name, {
              configurable: true, writable: true, enumerable: false,
              value: function (...a) {
                let r, err = null;
                try { r = real.apply(this, a); } catch (e) { err = e; }
                try { rec(label + ' ' + describe(a, r, err)); } catch (e) {}
                if (err) throw err;
                if (r && typeof r.then === 'function') {
                  return r.then((v) => { rec(label + ' resolved ' + (v ? (v.constructor && v.constructor.name) : String(v))); return v; },
                                (e) => { rec(label + ' REJECTED ' + (e && e.name) + ':' + String(e && e.message).slice(0, 80)); throw e; });
                }
                return r;
              },
            });
          } catch (e) { rec(label + ':hook-failed:' + e.name); }
        };
        const nm = (r, e) => e ? 'THREW:' + e.name + ':' + String(e.message).slice(0, 80)
                               : (r && r.constructor ? r.constructor.name : String(r));
        rec('navigator.gpu=' + (navigator.gpu ? (navigator.gpu.constructor && navigator.gpu.constructor.name) : String(navigator.gpu)));
        for (const n of ['GPU', 'GPUAdapter', 'GPUDevice', 'GPUCanvasContext', 'GPUBuffer', 'GPUQueue',
                         'GPUTexture', 'GPUCommandEncoder', 'GPUCommandBuffer', 'GPUAdapterInfo']) {
          rec('global ' + n + '=' + typeof globalThis[n]);
        }
        if (navigator.gpu) {
          wrap(Object.getPrototypeOf(navigator.gpu), 'requestAdapter', 'gpu.requestAdapter', (a, r, e) => nm(r, e));
          wrap(Object.getPrototypeOf(navigator.gpu), 'getPreferredCanvasFormat', 'gpu.getPreferredCanvasFormat', (a, r, e) => e ? 'THREW:' + e.name : String(r));
        }
        if (typeof GPUAdapter === 'function') {
          wrap(GPUAdapter.prototype, 'requestDevice', 'adapter.requestDevice', (a, r, e) => nm(r, e));
        }
        if (typeof GPUDevice === 'function') {
          for (const m of ['createBuffer', 'createTexture', 'createCommandEncoder', 'createShaderModule',
                           'createRenderPipeline', 'createComputePipeline', 'createBindGroup']) {
            wrap(GPUDevice.prototype, m, 'device.' + m, (a, r, e) => nm(r, e));
          }
        }
        if (typeof GPUCanvasContext === 'function') {
          wrap(GPUCanvasContext.prototype, 'configure', 'ctx.configure', (a, r, e) => e ? 'THREW:' + e.name : 'ok');
          wrap(GPUCanvasContext.prototype, 'getCurrentTexture', 'ctx.getCurrentTexture', (a, r, e) => nm(r, e));
        }
        if (typeof GPUBuffer === 'function') {
          wrap(GPUBuffer.prototype, 'mapAsync', 'buffer.mapAsync', (a, r, e) => nm(r, e));
          wrap(GPUBuffer.prototype, 'getMappedRange', 'buffer.getMappedRange',
               (a, r, e) => e ? 'THREW:' + e.name : 'byteLength=' + (r && r.byteLength));
        }
        if (typeof GPUQueue === 'function') {
          wrap(GPUQueue.prototype, 'submit', 'queue.submit', (a, r, e) => e ? 'THREW:' + e.name : 'n=' + (a[0] && a[0].length));
          wrap(GPUQueue.prototype, 'onSubmittedWorkDone', 'queue.onSubmittedWorkDone', (a, r, e) => nm(r, e));
        }
        if (typeof GPUCommandEncoder === 'function') {
          for (const m of ['beginRenderPass', 'beginComputePass', 'copyTextureToBuffer', 'copyBufferToBuffer', 'finish']) {
            wrap(GPUCommandEncoder.prototype, m, 'enc.' + m, (a, r, e) => nm(r, e));
          }
        }
        __send('report-gpu=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // Is the missing WebGPU readback weighed?
    //
    // report-gpu found the 4096 bytes. The widget takes a WebGPU adapter and
    // device, renders into a texture, copies it into a buffer, maps the buffer
    // and reads it -- and on this engine the last step, getMappedRange, hands
    // back no ArrayBuffer at all, so 32x32 pixels never reach the payload.
    // Chrome's readback is 4096 bytes of opaque black.
    //
    // Three knobs, because "absent" and "wrong" are different claims:
    // -undefined reproduces this engine exactly, -zeroes keeps the span but
    // fills it with the wrong pixels, and -passthru is the control that says
    // whether merely redefining the method is what costs the ticket.
    'gpu-mapped-undefined': beacon + `
      (() => {
        try {
          if (typeof GPUBuffer !== 'function') { __send('gpu-mapped-undefined=no-GPUBuffer'); return; }
          const real = GPUBuffer.prototype.getMappedRange;
          Object.defineProperty(GPUBuffer.prototype, 'getMappedRange', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) { try { real.apply(this, a); } catch (e) {} return undefined; },
          });
          __send('gpu-mapped-undefined=wrapped&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('gpu-mapped-undefined=cannot-wrap:' + e.name); }
      })();
    `,

    'gpu-mapped-zeroes': beacon + `
      (() => {
        try {
          if (typeof GPUBuffer !== 'function') { __send('gpu-mapped-zeroes=no-GPUBuffer'); return; }
          const real = GPUBuffer.prototype.getMappedRange;
          Object.defineProperty(GPUBuffer.prototype, 'getMappedRange', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) {
              const r = real.apply(this, a);
              return new ArrayBuffer(r && r.byteLength ? r.byteLength : 0);
            },
          });
          __send('gpu-mapped-zeroes=wrapped&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('gpu-mapped-zeroes=cannot-wrap:' + e.name); }
      })();
    `,

    'gpu-mapped-passthru': beacon + `
      (() => {
        try {
          if (typeof GPUBuffer !== 'function') { __send('gpu-mapped-passthru=no-GPUBuffer'); return; }
          const real = GPUBuffer.prototype.getMappedRange;
          Object.defineProperty(GPUBuffer.prototype, 'getMappedRange', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) { return real.apply(this, a); },
          });
          __send('gpu-mapped-passthru=wrapped&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('gpu-mapped-passthru=cannot-wrap:' + e.name); }
      })();
    `,

    // The same question asked from the other side: this arm, made to answer
    // the way Chrome answers.
    //
    // Every knob before this one perturbs Chrome and asks whether the ticket
    // survives, and sixteen families in a row have survived. That method has a
    // ceiling: it can only test differences Chrome can be made to imitate. This
    // one runs on THIS engine and repairs, at the JS level, the three payload
    // spans that are known to disagree -- the font list (54 names here, 6 in
    // Chrome), the permission states (prompt here, denied in Chrome) and the
    // duplicated stylesheet rules (41393 bytes here, 20696 in Chrome). If the
    // arm is ticketed with these three repaired, the door is a value after all
    // and the engine work is named. If it is refused with all three repaired,
    // the collected values are closed from the productive side too.
    'lp-chrome-values': beacon + `
      (() => {
        const KEEP = ['Apple Symbols', 'Galvji', 'Geneva', 'InaiMathi Bold', 'Luminari', 'PingFang HK Light'];
        // The list Chrome reports on this machine, in the order the widget
        // joins them, read off report-payload's 69-byte span.
        try {
          const real = FontFace.prototype.load;
          Object.defineProperty(FontFace.prototype, 'load', {
            configurable: true, writable: true, enumerable: false,
            value: function () {
              const fam = String(this.family || '').replace(/^["']|["']$/g, '');
              if (KEEP.indexOf(fam) === -1) {
                const e = new DOMException('A network error occurred.', 'NetworkError');
                return Promise.reject(e);
              }
              return real.call(this);
            },
          });
          __send('lp-chrome-values=font-wrapped');
        } catch (e) { __send('lp-chrome-values=font-cannot-wrap:' + e.name); }

        try {
          const perms = navigator.permissions;
          const proto = Object.getPrototypeOf(perms);
          const real = proto.query;
          Object.defineProperty(proto, 'query', {
            configurable: true, writable: true, enumerable: false,
            value: function (d) {
              return real.call(this, d).then((s) => {
                try {
                  Object.defineProperty(s, 'state', { configurable: true, get() { return 'denied'; } });
                } catch (e) {}
                return s;
              });
            },
          });
          __send('lp-chrome-values=perm-wrapped');
        } catch (e) { __send('lp-chrome-values=perm-cannot-wrap:' + e.name); }

        // A style element inside a closed shadow root leaks into
        // document.styleSheets here and does not in Chrome, which is why the
        // rule text comes out at exactly twice the length plus one separator.
        // Filtering on the owner node's root is the rule the spec already
        // states, so this is the repair rather than a trick.
        try {
          const d = Object.getOwnPropertyDescriptor(Document.prototype, 'styleSheets');
          if (!d || !d.get) { __send('lp-chrome-values=sheets-no-getter'); }
          else {
            const g = d.get;
            Object.defineProperty(Document.prototype, 'styleSheets', {
              configurable: true, enumerable: d.enumerable,
              get() {
                const list = g.call(this);
                const kept = [];
                for (let i = 0; i < list.length; i++) {
                  const s = list[i];
                  let owner = null;
                  try { owner = s.ownerNode; } catch (e) {}
                  if (owner && typeof owner.getRootNode === 'function' && owner.getRootNode() !== this) continue;
                  kept.push(s);
                }
                kept.item = (i) => kept[i] || null;
                return kept;
              },
            });
            __send('lp-chrome-values=sheets-wrapped');
          }
        } catch (e) { __send('lp-chrome-values=sheets-cannot-wrap:' + e.name); }
        __send('lp-chrome-values=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // What goes into the widget's FIRST post?
    //
    // report-payload hooks JSON.stringify, TextEncoder.encode and XHR.send, and
    // in the widget's frame the first of those to fire is the send itself: the
    // 4700-byte body of r2 is assembled without passing through any of them.
    // This engine's r2 is 180 bytes longer than Chrome's on every run, with r1
    // the same size to the byte, so the excess is widget-side and it is in
    // whatever builds that string. These are the other ways a long string gets
    // built: a join, a btoa, an encodeURIComponent, a big replace.
    'report-plain': beacon + `
      (() => {
        const hash = (s) => {
          let h = 5381;
          for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
          return h.toString(36);
        };
        const MIN = 200;
        const note = (what, s) => {
          try {
            const str = String(s);
            if (str.length < MIN) return;
            __send('plain=' + encodeURIComponent(what) + '&len=' + str.length + '&h=' + hash(str) +
                   '&head=' + encodeURIComponent(str.slice(0, 120)) +
                   '&at=' + encodeURIComponent(__where()));
          } catch (e) {}
        };
        try {
          const real = Array.prototype.join;
          Object.defineProperty(Array.prototype, 'join', {
            configurable: true, writable: true, enumerable: false,
            value: function (sep) {
              const r = real.call(this, sep);
              note('join(' + JSON.stringify(sep === undefined ? ',' : String(sep)) + ') n=' + this.length, r);
              return r;
            },
          });
        } catch (e) { __send('plain=join-failed:' + e.name); }
        for (const fn of ['btoa', 'encodeURIComponent', 'escape', 'encodeURI']) {
          try {
            if (typeof globalThis[fn] !== 'function') continue;
            const real = globalThis[fn];
            globalThis[fn] = function (s) { const r = real.call(globalThis, s); note(fn + '.in', s); note(fn + '.out', r); return r; };
          } catch (e) { __send('plain=' + fn + '-failed:' + e.name); }
        }
        try {
          const real = String.prototype.replace;
          Object.defineProperty(String.prototype, 'replace', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) { const r = real.apply(this, a); note('replace.out', r); return r; },
          });
        } catch (e) { __send('plain=replace-failed:' + e.name); }
        // The body of r2 comes out of join("") over 4716 single characters, so
        // the interesting string is whatever was cut into those characters.
        try {
          const real = String.prototype.split;
          Object.defineProperty(String.prototype, 'split', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) { note('split.in(' + JSON.stringify(String(a[0])) + ')', this); return real.apply(this, a); },
          });
        } catch (e) { __send('plain=split-failed:' + e.name); }
        try {
          const real = Array.from;
          Array.from = function (src, ...rest) {
            if (typeof src === 'string') note('Array.from.in', src);
            return real.call(Array, src, ...rest);
          };
        } catch (e) { __send('plain=from-failed:' + e.name); }
        __send('report-plain=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // The plaintext behind r2.
    //
    // report-plain showed the body of r2 leaving as join("") over 4716 single
    // characters, and no split or Array.from produced that array -- so it was
    // pushed one character at a time in a loop, and the loop reads its source
    // with charCodeAt or charAt. This records the RECEIVER of those calls, once
    // per distinct long string, which is the plaintext itself. Both methods are
    // hot, so the hook removes itself after a handful of distinct strings.
    'report-charsrc': beacon + `
      (() => {
        const hash = (s) => {
          let h = 5381;
          for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
          return h.toString(36);
        };
        const MIN = 1000;
        const CAP = 14;
        const seen = Object.create(null);
        let noted = 0;
        const hook = (name) => {
          try {
            const real = String.prototype[name];
            const restore = () => {
              Object.defineProperty(String.prototype, name, {
                configurable: true, writable: true, enumerable: false, value: real,
              });
            };
            Object.defineProperty(String.prototype, name, {
              configurable: true, writable: true, enumerable: false,
              value: function (i) {
                if (this.length >= MIN) {
                  const k = name + ':' + this.length;
                  if (!seen[k]) {
                    seen[k] = 1;
                    noted += 1;
                    const s = String(this);
                    __send('src=' + name + '&len=' + s.length + '&h=' + hash(s) +
                           '&head=' + encodeURIComponent(s.slice(0, 300)) +
                           '&tail=' + encodeURIComponent(s.slice(-120)) +
                           '&at=' + encodeURIComponent(__where()));
                    if (noted >= CAP) restore();
                  }
                }
                return real.call(this, i);
              },
            });
          } catch (e) { __send('src=' + name + '-failed:' + e.name); }
        };
        hook('charCodeAt');
        hook('charAt');
        __send('report-charsrc=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // Is the offer SDP weighed?
    //
    // report-charsrc caught the widget reading a createOffer SDP straight into
    // the payload: 8398 characters in Chrome, 7186 here. The gap is a codec
    // list -- this engine's canned offer predates H265 and the High-profile
    // H264 payload types, so nine payload numbers and their rtpmap, fmtp and
    // rtcp-fb lines are missing. That is 1212 characters, the largest single
    // content difference on this door. These two knobs cut the same nine
    // payload types out of Chrome's offer and, for the control, rewrite the
    // offer without changing it.
    'sdp-stale-codecs': beacon + `
      (() => {
        const DROP = { '121': 1, '49': 1, '50': 1, '51': 1, '52': 1, '53': 1, '122': 1, '123': 1, '124': 1 };
        const strip = (sdp) => {
          const lines = String(sdp).split(/\\r\\n|\\n/);
          const kept = [];
          for (const l of lines) {
            const m = /^a=(?:rtpmap|fmtp|rtcp-fb):(\\d+)/.exec(l);
            if (m && DROP[m[1]]) continue;
            if (l.indexOf('m=video ') === 0) {
              const p = l.split(' ');
              kept.push(p.filter((x, i) => i < 3 || !DROP[x]).join(' '));
              continue;
            }
            kept.push(l);
          }
          return kept.join('\\r\\n');
        };
        try {
          const real = RTCPeerConnection.prototype.createOffer;
          Object.defineProperty(RTCPeerConnection.prototype, 'createOffer', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) {
              const r = real.apply(this, a);
              if (!r || typeof r.then !== 'function') return r;
              return r.then((d) => {
                try {
                  const before = d.sdp.length;
                  const after = strip(d.sdp);
                  __send('sdp-stale-codecs=stripped&from=' + before + '&to=' + after.length +
                         '&at=' + encodeURIComponent(__where()));
                  return { type: d.type, sdp: after };
                } catch (e) { __send('sdp-stale-codecs=strip-threw:' + e.name); return d; }
              });
            },
          });
          __send('sdp-stale-codecs=wrapped&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('sdp-stale-codecs=cannot-wrap:' + e.name); }
      })();
    `,

    'sdp-passthru': beacon + `
      (() => {
        try {
          const real = RTCPeerConnection.prototype.createOffer;
          Object.defineProperty(RTCPeerConnection.prototype, 'createOffer', {
            configurable: true, writable: true, enumerable: false,
            value: function (...a) {
              const r = real.apply(this, a);
              if (!r || typeof r.then !== 'function') return r;
              return r.then((d) => {
                __send('sdp-passthru=seen&len=' + d.sdp.length + '&at=' + encodeURIComponent(__where()));
                return { type: d.type, sdp: d.sdp };
              });
            },
          });
          __send('sdp-passthru=wrapped&at=' + encodeURIComponent(__where()));
        } catch (e) { __send('sdp-passthru=cannot-wrap:' + e.name); }
      })();
    `,

    // Does the exchange stop because something threw?
    //
    // The response to r3 on this engine is not a refusal: it carries a fresh
    // cf-chl-gen and 170KB of body, which is the server asking for another
    // round. Chrome is ticketed at r3 and never needs one. So the arms differ
    // not only in the verdict but in what happens next -- this engine is handed
    // a fourth challenge and never posts it. This records every uncaught error
    // and rejection in every document, which is the cheapest way to ask whether
    // the fourth round dies on the way out.
    'report-errors': beacon + `
      (() => {
        const cut = (s) => String(s == null ? s : s).slice(0, 300);
        try {
          addEventListener('error', (e) => {
            __send('err=' + encodeURIComponent(cut(e.message)) +
                   '&src=' + encodeURIComponent(cut(e.filename) + ':' + e.lineno + ':' + e.colno) +
                   '&stack=' + encodeURIComponent(cut(e.error && e.error.stack)) +
                   '&at=' + encodeURIComponent(__where()));
          }, true);
          addEventListener('unhandledrejection', (e) => {
            const r = e.reason;
            __send('rej=' + encodeURIComponent(cut(r && (r.message || r))) +
                   '&name=' + encodeURIComponent(cut(r && r.name)) +
                   '&stack=' + encodeURIComponent(cut(r && r.stack)) +
                   '&at=' + encodeURIComponent(__where()));
          }, true);
        } catch (e) { __send('report-errors=listen-failed:' + e.name); }
        // console.error is where a library reports the failure it did catch --
        // the Turnstile interstitial's own "Unhandled error" line comes out
        // here, not through the error event.
        try {
          for (const level of ['error', 'warn']) {
            const real = console[level];
            console[level] = function (...a) {
              try {
                __send('con=' + level + '&msg=' + encodeURIComponent(a.map(cut).join(' ').slice(0, 300)) +
                       '&at=' + encodeURIComponent(__where()));
              } catch (e) {}
              return real.apply(console, a);
            };
          }
        } catch (e) { __send('report-errors=console-failed:' + e.name); }
        __send('report-errors=installed&at=' + encodeURIComponent(__where()));
      })();
    `,

    // What do the widget's workers send back?
    //
    // The font list is built somewhere no knob has reached: not by any DOM or
    // canvas measurement in the frame (report-font-probe found no per-font
    // loop), and the frame is the only document the harness can script. What is
    // left is the two blob workers -- and evaluating into those stops the
    // exchange at r1, so they cannot be entered. They can still be listened to:
    // this records every message crossing the boundary in both directions,
    // from the frame side, which changes nothing about how they run.
    'report-worker-traffic': beacon + `
      (() => {
        const cut = (v) => {
          try {
            if (typeof v === 'string') return 'str[' + v.length + ']' + v.slice(0, 300);
            if (v && typeof v === 'object') {
              const j = JSON.stringify(v);
              return 'obj[' + j.length + ']' + j.slice(0, 300);
            }
            return typeof v + ':' + String(v).slice(0, 120);
          } catch (e) { return 'unshapeable:' + e.name; }
        };
        const rec = (s) => __send('wt=' + encodeURIComponent(String(s).slice(0, 400)) +
                                  '&at=' + encodeURIComponent(__where()));
        try {
          const Real = window.Worker;
          if (typeof Real !== 'function') { rec('no-Worker'); return; }
          let n = 0;
          const Hooked = new Proxy(Real, {
            construct(target, args, nt) {
              const id = ++n;
              const w = Reflect.construct(target, args, nt);
              try {
                const realPost = w.postMessage.bind(w);
                w.postMessage = function (m, ...rest) {
                  rec('w' + id + ' ->worker ' + cut(m));
                  return realPost(m, ...rest);
                };
                w.addEventListener('message', (e) => rec('w' + id + ' <-worker ' + cut(e.data)));
                w.addEventListener('error', (e) => rec('w' + id + ' error ' + ((e && e.message) || '')));
              } catch (e) { rec('w' + id + ' cannot-listen:' + e.name); }
              return w;
            },
          });
          Object.defineProperty(window, 'Worker', {
            configurable: true, writable: true, enumerable: false, value: Hooked,
          });
          rec('report-worker-traffic=installed');
        } catch (e) { rec('fail=' + e.name); }
      })();
    `,

    // The mechanism behind the font span, handed to Chrome.
    //
    // The detector is `new FontFace(n, 'local("X")').load()`: Chrome resolves
    // it for an installed family and rejects with NetworkError otherwise, and
    // the names that resolve are what gets joined with pipes and sent. Chrome
    // keeps six on this Mac; this engine resolves every one of the fifty-four
    // candidates, including Aldhabi, Bahnschrift and Adwaita Sans -- Windows
    // and GNOME families that no Mac has. Nothing else explains the span: span
    // width, canvas and OffscreenCanvas measureText, every TextMetrics field,
    // document.fonts.check and queryLocalFonts all agree between the arms.
    //
    // This makes Chrome answer the way this engine does.
    'all-local-fonts': beacon + `
      __send('all-local-fonts=' + encodeURIComponent(__where()));
      try {
        const real = FontFace.prototype.load;
        Object.defineProperty(FontFace.prototype, 'load', {
          configurable: true, writable: true, enumerable: false,
          value: function () { const self = this; return real.call(this).catch(function () { return self; }); },
        });
        __send('fontface-load-forced&at=' + encodeURIComponent(__where()));
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The control. Same property, same defineProperty, real behaviour --
    // heap-passthru is why this is never optional.
    'fontface-passthru': beacon + `
      __send('fontface-passthru=' + encodeURIComponent(__where()));
      try {
        const real = FontFace.prototype.load;
        Object.defineProperty(FontFace.prototype, 'load', {
          configurable: true, writable: true, enumerable: false,
          value: function () { return real.call(this); },
        });
        __send('fontface-passthru-installed&at=' + encodeURIComponent(__where()));
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The CSS span is exactly twice as long here, and this is why.
    //
    // report-payload measured the widget's stylesheet text at 20696 bytes in
    // Chrome and 41393 here -- 2 x 20696 + 1, the extra byte being one more
    // pipe separator. That arithmetic says the collector saw every rule twice,
    // not that the rules serialise differently, and the cause is isolated: a
    // <style> inside a CLOSED shadow root leaks into document.styleSheets in
    // this engine. Chrome keeps document.styleSheets at 1 and the rules
    // unreadable from the document; here the count goes to 2 and the shadow
    // root's rules are readable. The widget builds its UI in a closed shadow
    // root -- its own 85-byte span carries `attachShadow` and "closed" -- so a
    // walk of document.styleSheets picks up its sheet a second time.
    //
    // This hands Chrome the doubled list, keeping every entry real.
    'double-stylesheets': beacon + `
      __send('double-stylesheets=' + encodeURIComponent(__where()));
      try {
        const proto = Object.getPrototypeOf(document);
        const d = Object.getOwnPropertyDescriptor(proto, 'styleSheets') ||
                  Object.getOwnPropertyDescriptor(Document.prototype, 'styleSheets');
        if (!d || !d.get) { __send('no-styleSheets-getter&at=' + encodeURIComponent(__where())); }
        else {
          const g = d.get;
          Object.defineProperty(Document.prototype, 'styleSheets', {
            configurable: true, enumerable: d.enumerable,
            get() {
              const real = g.call(this);
              const doubled = [];
              for (let i = 0; i < real.length; i++) doubled.push(real[i], real[i]);
              doubled.item = function (i) { return this[i] === undefined ? null : this[i]; };
              return doubled;
            },
          });
          __send('stylesheets-doubled&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The control: same getter replaced through the same defineProperty, same
    // array shape, but each sheet appears once. If this loses the ticket too,
    // the refusal is about handing back an Array where a StyleSheetList
    // belongs, and says nothing about the doubling.
    'stylesheets-passthru': beacon + `
      __send('stylesheets-passthru=' + encodeURIComponent(__where()));
      try {
        const d = Object.getOwnPropertyDescriptor(Document.prototype, 'styleSheets');
        if (!d || !d.get) { __send('no-styleSheets-getter&at=' + encodeURIComponent(__where())); }
        else {
          const g = d.get;
          Object.defineProperty(Document.prototype, 'styleSheets', {
            configurable: true, enumerable: d.enumerable,
            get() {
              const real = g.call(this);
              const copy = [];
              for (let i = 0; i < real.length; i++) copy.push(real[i]);
              copy.item = function (i) { return this[i] === undefined ? null : this[i]; };
              return copy;
            },
          });
          __send('stylesheets-copied&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('fail=' + e.name); }
    `,

    // The fourth and last of the payload differences report-payload turned up.
    //
    // The widget asks permissions.query for geolocation, notifications, camera
    // and microphone and puts the four states in the payload. Chrome answers
    // `denied` for all four; this engine answers `prompt`. This gives Chrome
    // this engine's answer.
    'permissions-prompt': beacon + `
      __send('permissions-prompt=' + encodeURIComponent(__where()));
      try {
        const real = navigator.permissions.query;
        Object.defineProperty(Permissions.prototype, 'query', {
          configurable: true, writable: true, enumerable: false,
          value: function (desc) {
            return real.call(this, desc).then(function (st) {
              return new Proxy(st, {
                get(t, k) {
                  if (k === 'state') return 'prompt';
                  const v = t[k];
                  return typeof v === 'function' ? v.bind(t) : v;
                },
              });
            });
          },
        });
        __send('permissions-forced&at=' + encodeURIComponent(__where()));
      } catch (e) { __send('fail=' + e.name); }
    `,

    // Its control: the same replacement, the same Proxy, the real state.
    'permissions-passthru': beacon + `
      __send('permissions-passthru=' + encodeURIComponent(__where()));
      try {
        const real = navigator.permissions.query;
        Object.defineProperty(Permissions.prototype, 'query', {
          configurable: true, writable: true, enumerable: false,
          value: function (desc) {
            return real.call(this, desc).then(function (st) {
              return new Proxy(st, {
                get(t, k) {
                  const v = t[k];
                  return typeof v === 'function' ? v.bind(t) : v;
                },
              });
            });
          },
        });
        __send('permissions-passthru-installed&at=' + encodeURIComponent(__where()));
      } catch (e) { __send('fail=' + e.name); }
    `,

    // --- reporting knobs: measure, do not break ------------------------------

    // What does the widget's frame see when it looks at its parent?
    //
    // The Turnstile widget runs cross-origin on challenges.cloudflare.com, so
    // every reach for `parent` / `top` / `opener` crosses a security boundary
    // that Chrome enforces with a V8 access check. This engine has an open plan
    // saying it does not (`cross-origin-access-check`: `JSON.stringify(w)`
    // answers `"{}"` where Chrome throws) -- and a cross-origin frame that can
    // read its parent is a large thing for a guard to notice, from the one
    // document that builds the ~90KB payload.
    //
    // This changes nothing. It reports, from every document it lands in, so the
    // two arms can be compared where it actually matters.
    'report-crossorigin': beacon + `
      (() => {
        const ask = (label, fn) => {
          let r;
          try { const v = fn(); r = v === undefined ? 'undefined' : String(v); }
          catch (e) { r = 'threw:' + e.name; }
          return label + '=' + r;
        };
        const bits = [
          'where=' + __where(),
          ask('sameOriginAsTop', () => { try { return window.top.location.href ? 'readable' : 'empty'; } catch (e) { throw e; } }),
          ask('parentHref', () => window.parent.location.href),
          ask('topOrigin', () => window.top.location.origin),
          ask('parentDocument', () => String(window.parent.document)),
          ask('stringifyParent', () => JSON.stringify(window.parent)),
          ask('parentKeys', () => Object.keys(window.parent).length),
          ask('parentProtoIsWindow', () => Object.getPrototypeOf(window.parent) === null ? 'null' : 'not-null'),
          ask('opener', () => String(window.opener)),
          ask('frameElement', () => String(window.frameElement)),
          ask('parentTypeof', () => typeof window.parent),
          ask('isTop', () => window.top === window),
        ];
        __send(bits.map(encodeURIComponent).join('&'));
      })();
    `,

    // Hand THIS ENGINE Chrome's cross-origin boundary, from a page, to see
    // whether that is what the ticket turns on.
    //
    // Measured difference (report-crossorigin, both arms, in the widget's own
    // frame): reaching across an origin for `top.location` throws
    // **SecurityError** in Chrome and **TypeError** here, and
    // `JSON.stringify(crossOriginWindow)` throws in Chrome and answers `"{}"`
    // here. The second is the headline of the open `cross-origin-access-check`
    // plan; the first is a new one.
    //
    // This is the inverse of every knob above: it runs on the arm that FAILS and
    // adds a capability rather than removing one. If the ticket appears, the
    // engine change is named. Watch the round count -- a knob that stops the
    // exchange is not a knob that passed it.
    'crossorigin-securityerror': beacon + `
      __send('crossorigin-securityerror=' + encodeURIComponent(__where()));
      try {
        const isCross = (w) => {
          try { void w.location.href; return false; } catch (e) { return true; }
        };
        const raise = () => {
          // Chrome's shape: a DOMException named SecurityError, not a TypeError.
          throw new DOMException(
            "Blocked a frame with origin from accessing a cross-origin frame.",
            'SecurityError');
        };
        const opaque = (real) => new Proxy(real, {
          get(t, k) {
            // The handful Chrome does allow across an origin.
            if (k === 'postMessage' || k === 'closed' || k === 'frames' ||
                k === 'length' || k === 'opener' || k === 'parent' ||
                k === 'top' || k === 'self' || k === 'window' || k === 'close' ||
                k === 'blur' || k === 'focus' || k === Symbol.toStringTag) {
              const v = t[k];
              return typeof v === 'function' ? v.bind(t) : v;
            }
            raise();
          },
          set() { raise(); },
          has() { raise(); },
          getOwnPropertyDescriptor() { raise(); },
          ownKeys() { raise(); },
        });
        // Per-name try/catch: window.top is non-configurable in this engine
        // ("Cannot redefine property: top"), and a single catch around the loop
        // aborted before parent was ever tried -- which made a void run look
        // like a negative one.
        for (const name of ['parent', 'top']) {
          let real;
          try { real = window[name]; } catch (e) { continue; }
          if (!real || real === window || !isCross(real)) continue;
          const wrapped = opaque(real);
          try {
            Object.defineProperty(window, name, {
              configurable: true, enumerable: true, get() { return wrapped; },
            });
            __send('wrapped=' + name + '&at=' + encodeURIComponent(__where()));
          } catch (e) {
            __send('cannot-wrap=' + name + '&why=' + encodeURIComponent(e.message) +
                   '&at=' + encodeURIComponent(__where()));
          }
        }
      } catch (e) { __send('crossorigin-failed=' + e.name + ':' + e.message); }
    `,

    // Does the guard LOOK at its parent at all?
    //
    // Before anyone changes the engine's cross-origin boundary -- which needs a
    // V8 access-check shim, not a page-level patch -- this asks whether the
    // widget ever reaches across it. window.parent is wrappable here (window.top
    // is not: "Cannot redefine property: top"), so a counting proxy on parent
    // answers it. If nothing is ever read, the boundary's error type cannot be
    // what the ticket turns on and the whole direction is ruled out for the price
    // of one run.
    'count-parent-reads': beacon + `
      __send('count-parent-reads=' + encodeURIComponent(__where()));
      try {
        let real;
        try { real = window.parent; } catch (e) { real = null; }
        if (!real || real === window) { __send('no-parent&at=' + encodeURIComponent(__where())); }
        else {
          let crossOrigin = false;
          try { void real.location.href; } catch (e) { crossOrigin = true; }
          const seen = Object.create(null);
          const proxy = new Proxy(real, {
            get(t, k) {
              const key = typeof k === 'symbol' ? 'sym:' + String(k) : String(k);
              if (!seen[key]) {
                seen[key] = 1;
                __send('parent-read=' + encodeURIComponent(key) +
                       '&cross=' + crossOrigin + '&at=' + encodeURIComponent(__where()));
              }
              const v = t[k];
              return typeof v === 'function' ? v.bind(t) : v;
            },
          });
          Object.defineProperty(window, 'parent', {
            configurable: true, enumerable: true, get() { return proxy; },
          });
          __send('counting=parent&cross=' + crossOrigin + '&at=' + encodeURIComponent(__where()));
        }
      } catch (e) { __send('count-failed=' + e.name + ':' + encodeURIComponent(e.message)); }
    `,

    // Which of the candidate families does the guard TOUCH at all?
    //
    // Breaking one family per run costs two runs a family and answers only the
    // family guessed. This asks the station instead: every candidate global,
    // every own property of Navigator/Screen, is replaced with a pass-through
    // accessor that records the first read and hands back the real value. What
    // comes back is the list of names the challenge actually reached for, and
    // every candidate NOT on it is ruled out for the price of one run -- the
    // same move that closed the cross-origin family with count-parent-reads.
    //
    // It changes no value, so a lost ticket here would be about the hooking, not
    // about any family; console-passthru already showed hooking alone is not
    // weighed. Reads are flushed on a timer because the interesting ones happen
    // long after the document does.
    'report-reads': beacon + `
      (() => {
        const seen = [];
        const mark = (k) => { if (seen.indexOf(k) === -1) seen.push(k); };
        let flushed = 0;
        const flush = () => {
          const batch = seen.slice(flushed);
          if (!batch.length) return;
          flushed = seen.length;
          for (let i = 0; i < batch.length; i += 16) {
            __send('at=' + encodeURIComponent(__where()) +
                   '&reads=' + encodeURIComponent(batch.slice(i, i + 16).join(',')));
          }
        };
        for (const ms of [2000, 5000, 9000, 13000, 17000, 20000]) setTimeout(flush, ms);

        const wrap = (obj, label, names) => {
          let done = 0;
          for (const n of names) {
            let d;
            try { d = Object.getOwnPropertyDescriptor(obj, n); } catch (e) { continue; }
            if (!d || !d.configurable) continue;
            try {
              if (d.get) {
                const g = d.get;
                Object.defineProperty(obj, n, {
                  configurable: true, enumerable: d.enumerable,
                  get() { mark(label + '.' + n); return g.call(this); },
                  set: d.set || undefined,
                });
              } else {
                let v = d.value;
                Object.defineProperty(obj, n, {
                  configurable: true, enumerable: d.enumerable,
                  get() { mark(label + '.' + n); return v; },
                  set(nv) { v = nv; },
                });
              }
              done += 1;
            } catch (e) { /* leave it alone */ }
          }
          return done;
        };

        // Curated, because wrapping all of window would put an accessor on
        // document and location and change how the page loads.
        const WIN = ['Notification','RTCPeerConnection','webkitRTCPeerConnection',
          'RTCDataChannel','SharedArrayBuffer','Atomics','WeakRef','FinalizationRegistry',
          'structuredClone','IntersectionObserver','ResizeObserver','MutationObserver',
          'PerformanceObserver','ReportingObserver','requestIdleCallback','cancelIdleCallback',
          'matchMedia','visualViewport','screen','speechSynthesis','SpeechSynthesisUtterance',
          'indexedDB','caches','crypto','isSecureContext','chrome','external','styleMedia',
          'openDatabase','webkitStorageInfo','offscreenBuffering','BroadcastChannel',
          'CompressionStream','DecompressionStream','TransformStream','ReadableStream',
          'DeviceOrientationEvent','DeviceMotionEvent','ondeviceorientation','ondevicemotion',
          'PaymentRequest','trustedTypes','scheduler','cookieStore','navigation',
          'documentPictureInPicture','sharedStorage','launchQueue','onbeforeinstallprompt',
          'AudioContext','webkitAudioContext','OfflineAudioContext','MediaRecorder',
          'MediaSource','ImageDecoder','VideoDecoder','AudioDecoder','GPU','gpu',
          'showOpenFilePicker','showDirectoryPicker','queueMicrotask','reportError',
          'devicePixelRatio','innerWidth','innerHeight','outerWidth','outerHeight',
          'screenX','screenY','scrollX','scrollY','name','opener','frameElement',
          'localStorage','sessionStorage','performance','origin','crossOriginIsolated'];

        const own = (o) => { try { return Object.getOwnPropertyNames(o); } catch (e) { return []; } };
        const counts = [];
        counts.push('win:' + wrap(window, 'win', WIN));
        try { counts.push('nav:' + wrap(Navigator.prototype, 'nav', own(Navigator.prototype))); } catch (e) {}
        try { counts.push('scr:' + wrap(Screen.prototype, 'scr', own(Screen.prototype))); } catch (e) {}
        try { counts.push('nk:' + wrap(NavigatorUAData.prototype, 'nk', own(NavigatorUAData.prototype))); } catch (e) {}
        try { counts.push('vv:' + wrap(VisualViewport.prototype, 'vv', own(VisualViewport.prototype))); } catch (e) {}
        try { counts.push('mql:' + wrap(MediaQueryList.prototype, 'mql', own(MediaQueryList.prototype))); } catch (e) {}
        try { counts.push('perf:' + wrap(Performance.prototype, 'perf', ['memory','timeOrigin','timing','navigation','eventCounts'])); } catch (e) {}
        __send('report-reads=' + encodeURIComponent(__where()) + '&wrapped=' + encodeURIComponent(counts.join(' ')));
      })();
    `,

    // What do the calls the widget makes ANSWER?
    //
    // `report-reads` names the properties the widget touches and stops there:
    // it sees `nav.permissions` read and `mql.matches` read, not which media
    // query was asked or which permission came back. Once the read sets of the
    // two arms agree -- and they do, to two globals that are provably not
    // weighed -- what is left is the answers, and this records them on both
    // arms through one piece of code so they can be diffed.
    //
    // This one is allowed to cost the ticket. It is a recorder, not a family
    // knob: the log is the output, and the arm that matters has no ticket to
    // lose anyway.
    'report-calls': beacon + `
      (() => {
        const rec = (s) => __send('call=' + encodeURIComponent(String(s).slice(0, 180)) +
                                  '&at=' + encodeURIComponent(__where()));
        const shape = (v) => {
          try {
            if (v === undefined) return 'undefined';
            if (v === null) return 'null';
            if (typeof v === 'object') {
              const keys = Object.keys(v);
              if (keys.length) return JSON.stringify(v).slice(0, 140);
              return Object.prototype.toString.call(v) + '/len=' + (v.length === undefined ? '-' : v.length);
            }
            return typeof v + ':' + String(v);
          } catch (e) { return 'unshapeable:' + e.name; }
        };

        // The query strings themselves, which the read log cannot show.
        try {
          const real = window.matchMedia;
          Object.defineProperty(window, 'matchMedia', {
            configurable: true, writable: true, enumerable: false,
            value: function (q) {
              const mql = real.call(window, q);
              rec('matchMedia(' + q + ')=' + mql.matches);
              return mql;
            },
          });
        } catch (e) { rec('matchMedia-hook-failed:' + e.name); }

        const hook = (owner, name, label) => {
          try {
            if (!owner || typeof owner[name] !== 'function') { rec(label + '=absent'); return; }
            const real = owner[name];
            Object.defineProperty(owner, name, {
              configurable: true, writable: true, enumerable: false,
              value: function (...args) {
                let r;
                try { r = real.apply(this, args); }
                catch (e) { rec(label + '(' + shape(args[0]) + ') threw ' + e.name); throw e; }
                if (r && typeof r.then === 'function') {
                  r.then((v) => rec(label + '(' + shape(args[0]) + ') resolved ' + shape(v)),
                    (e) => rec(label + '(' + shape(args[0]) + ') rejected ' + (e && e.name)));
                } else {
                  rec(label + '(' + shape(args[0]) + ') = ' + shape(r));
                }
                return r;
              },
            });
          } catch (e) { rec(label + '-hook-failed:' + e.name); }
        };

        hook(navigator, 'getGamepads', 'getGamepads');
        hook(navigator, 'getBattery', 'getBattery');
        hook(navigator, 'sendBeacon', 'sendBeacon');
        try { hook(navigator.permissions, 'query', 'permissions.query'); } catch (e) {}
        try { hook(navigator.storage, 'estimate', 'storage.estimate'); } catch (e) {}
        try { hook(navigator.mediaCapabilities, 'decodingInfo', 'mediaCapabilities.decodingInfo'); } catch (e) {}
        try { hook(navigator.userAgentData, 'getHighEntropyValues', 'uaData.getHighEntropyValues'); } catch (e) {}
        try { hook(navigator.userAgentData, 'toJSON', 'uaData.toJSON'); } catch (e) {}
        try { hook(window.speechSynthesis, 'getVoices', 'getVoices'); } catch (e) {}
        try { hook(window.indexedDB, 'databases', 'indexedDB.databases'); } catch (e) {}
        try { hook(window.caches, 'keys', 'caches.keys'); } catch (e) {}

        // performance.memory is read, and it is three numbers, so record them.
        try {
          const m = performance.memory;
          rec('performance.memory=' + (m === undefined ? 'absent'
            : [m.jsHeapSizeLimit, m.totalJSHeapSize, m.usedJSHeapSize].join(',')));
        } catch (e) { rec('performance.memory threw ' + e.name); }
        try { rec('connection=' + shape(navigator.connection)); } catch (e) {}
        try {
          const c = navigator.connection;
          if (c) rec('connection.values=' + [c.effectiveType, c.rtt, c.downlink, c.saveData].join(','));
        } catch (e) {}
        rec('report-calls=installed');
      })();
    `,

    // Does the challenge run code in a Worker, and does this engine follow it
    // there?
    //
    // Chrome's target list on a passing run holds five auto-attached targets,
    // two of which are `worker:blob:https://challenges.cloudflare.com/...`;
    // this engine's holds one. That is not yet a finding -- a CDP client that
    // never reports worker targets looks identical from the outside -- so this
    // asks from inside the page instead: hook the Worker constructor and
    // URL.createObjectURL and beacon every construction, on both arms, through
    // the same code.
    //
    // It matters more than one family because `Page.addScriptToEvaluateOnNewDocument`
    // cannot reach a worker at all: if the payload is assembled in one, then
    // every family this session excluded was excluded in the wrong document.
    'report-workers': beacon + `
      (() => {
        const line = (q) => __send('at=' + encodeURIComponent(__where()) + '&' + q);
        let blobs = 0;
        try {
          const realCreate = URL.createObjectURL;
          Object.defineProperty(URL, 'createObjectURL', {
            configurable: true, writable: true, enumerable: false,
            value: function (obj) {
              const url = realCreate.call(URL, obj);
              blobs += 1;
              let size = -1, type = '';
              try { size = obj.size; type = obj.type; } catch (e) { /* not a Blob */ }
              line('createObjectURL=' + blobs + '&size=' + size + '&type=' + encodeURIComponent(String(type)));
              return url;
            },
          });
        } catch (e) { line('createObjectURL-failed=' + e.name); }

        const hookCtor = (name) => {
          let Real;
          try { Real = window[name]; } catch (e) { return 'absent'; }
          if (typeof Real !== 'function') return 'absent';
          try {
            const Hooked = new Proxy(Real, {
              construct(target, args, nt) {
                const w = Reflect.construct(target, args, nt);
                line(name + '=new&url=' + encodeURIComponent(String(args[0]).slice(0, 80)));
                try {
                  w.addEventListener('message', () => line(name + '=message'), { once: true });
                  w.addEventListener('error', (e) => line(name + '=error&msg=' +
                    encodeURIComponent(String((e && e.message) || ''))), { once: true });
                } catch (e) { line(name + '=cannot-listen&why=' + e.name); }
                return w;
              },
            });
            Object.defineProperty(window, name, {
              configurable: true, writable: true, enumerable: false, value: Hooked,
            });
            return 'hooked';
          } catch (e) { return 'failed:' + e.name; }
        };

        const states = ['Worker', 'SharedWorker'].map((n) => n + ':' + hookCtor(n));
        let sw = 'absent';
        try {
          if (navigator.serviceWorker) {
            const realReg = navigator.serviceWorker.register;
            navigator.serviceWorker.register = function (...a) {
              line('serviceWorker=register&url=' + encodeURIComponent(String(a[0]).slice(0, 80)));
              return realReg.apply(this, a);
            };
            sw = 'hooked';
          }
        } catch (e) { sw = 'failed:' + e.name; }
        line('report-workers=' + encodeURIComponent(states.join(' ') + ' serviceWorker:' + sw));
        for (const ms of [5000, 12000, 19000]) setTimeout(() => line('tick=' + ms + '&blobs=' + blobs), ms);
      })();
    `,
};
