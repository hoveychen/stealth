// Knobs for b84-knob.mjs. Each is a source string injected into every document
// before anything on the page runs.
//
// The first three are controls, and they earn their place: a knob that changes
// nothing and a knob that never ran look identical from the wire, so nothing
// here is interpretable until `alive` has been seen to beacon from the very
// document the guard runs in, and `break-encoder` has been seen to move the
// POST.
const beacon = `
  const __send = (q) => { try { new Image().src = location.origin + '/__b84?' + q; } catch (e) {} };
`;

// Rewrite the `<n>px,<n>px,...` section on its way into the payload. A null
// replacement means "the same values, each one larger", the tamper control.
const pxRewrite = (replacement) => `
  const __PX = /^\\d+px(,\\d+px)+$/;
  const __sub = ${replacement === null ? 'null' : JSON.stringify(replacement)};
  (() => {
    const real = TextEncoder.prototype.encode;
    Object.defineProperty(TextEncoder.prototype, 'encode', {
      configurable: true, writable: true, enumerable: false,
      value: function (input) {
        try {
          const s = String(input === undefined ? '' : input);
          if (__PX.test(s)) {
            const out = __sub !== null
              ? __sub
              : s.split(',').map((p) => (parseInt(p, 10) + 1) + 'px').join(',');
            __send('rewrote=' + encodeURIComponent(s) + '&to=' + encodeURIComponent(out));
            return real.call(this, out);
          }
        } catch (e) {}
        return real.call(this, input);
      },
    });
  })();
`;

// The voices section is `<name>,<voice>,<lang>,<local>,<default>;` repeated.
// Chrome hands the guard 9619 characters of it; this engine hands over the
// empty string. `mode` 'empty' sends ours, 'nudge' sends a list of the same
// shape with one name changed -- the tamper control.
const voiceRewrite = (mode) => `
  (() => {
    const real = TextEncoder.prototype.encode;
    const isVoices = (s) => s.length > 1000 && s.indexOf(';') > 0 && /^[^,;]+,[^,;]+,[a-z]{2}-[A-Za-z]+,[01],[01];/.test(s);
    Object.defineProperty(TextEncoder.prototype, 'encode', {
      configurable: true, writable: true, enumerable: false,
      value: function (input) {
        try {
          const s = String(input === undefined ? '' : input);
          if (isVoices(s)) {
            const out = ${mode === 'empty' ? "''" : "s.replace(/^[^,]+/, 'Zamantha')"};
            __send('voices=' + s.length + '&to=' + out.length);
            return real.call(this, out);
          }
        } catch (e) {}
        return real.call(this, input);
      },
    });
  })();
`;

export const KNOBS = {
    // No injection at all: the reference reading for this station and engine.
    none: '',

    // Does an injected script reach the challenge document? On both stations the
    // first document is a 429 that the guard itself serves, and a script that
    // only lands on the *next* document measures a page the guard already
    // cleared. This beacons the document's own status-bearing URL right away and
    // again once, so its absence is proof of non-arrival rather than of timing.
    alive: beacon + `
      __send('alive=1&url=' + encodeURIComponent(location.href) + '&t=' + Date.now());
      setTimeout(() => __send('alive=2&ready=' + document.readyState), 1500);
    `,

    // A knob that must break the payload. Kasada feeds its sections through
    // TextEncoder.encode; taking it away should move postLen or lose the POST.
    // If this changes nothing, injection is not reaching the guard's realm and
    // every negative result below is meaningless.
    'break-encoder': beacon + `
      __send('knob=break-encoder');
      try { delete window.TextEncoder; } catch (e) {}
      try { Object.defineProperty(window, 'TextEncoder', { get() { throw new TypeError('nope'); } }); } catch (e) {}
    `,

    // Substitute one payload section and keep everything else. The guard hands
    // each section to TextEncoder.encode as plaintext, so rewriting the argument
    // there changes exactly that section of the body and nothing else -- a knob
    // with the granularity of a single answer.
    //
    // The section at stake is four lengths, `<n>px,<n>px,<n>px,<n>px`. Chrome
    // sends six-figure values there and this engine sends `0px,0px,0px,0px`.
    // `px-zero` makes Chrome send ours.
    'px-zero': beacon + pxRewrite('0px,0px,0px,0px'),

    // The control `px-zero` needs. A rewritten section is also a *tampered*
    // section, and a guard that hashes its own values elsewhere would reject the
    // body for that alone -- which would look exactly like "the station weighs
    // this answer". This knob rewrites the same section, through the same code
    // path, to values one larger: still six figures, still plausible, still not
    // what the guard computed. A ticket here and no ticket under `px-zero`
    // separates the two explanations; losing the ticket here too means the knob
    // measures tamper detection and proves nothing about the values.
    'px-nudge': beacon + pxRewrite(null),

    // Make Chrome hand over the empty voice list this engine hands over.
    'voices-empty': beacon + voiceRewrite('empty'),
    // Same rewrite path, a list of the same size with one name changed: the
    // control that separates "the station weighs this answer" from "the station
    // noticed the section was rewritten at all".
    'voices-nudge': beacon + voiceRewrite('nudge'),

    // The control both rewrite knobs depend on. Emptying the 9619-character
    // voice list left the posted body the same size, which has two readings: the
    // section is folded into a fixed-width digest, or the rewrite never reached
    // the body at all. In the second reading every "still got a ticket" above
    // measures nothing.
    //
    // This appends twenty thousand characters to a section. If the body grows,
    // sections reach it and the negatives stand. If the body does not move, the
    // hook is downstream of whatever builds the payload and the knob needs to be
    // placed somewhere else.
    'px-inflate': beacon + `
      const __PX = /^\\d+px(,\\d+px)+$/;
      (() => {
        const real = TextEncoder.prototype.encode;
        Object.defineProperty(TextEncoder.prototype, 'encode', {
          configurable: true, writable: true, enumerable: false,
          value: function (input) {
            try {
              const s = String(input === undefined ? '' : input);
              if (__PX.test(s)) {
                const out = s + ',' + '9px,'.repeat(5000);
                __send('inflate=' + s.length + '&to=' + out.length);
                return real.call(this, out);
              }
            } catch (e) {}
            return real.call(this, input);
          },
        });
      })();
    `,

    // The payload's shape rather than its content.
    //
    // Section content turned out not to drive the body's size: twenty thousand
    // characters appended to a section moved it by nothing, so the guard folds
    // each section to a fixed width. Yet this engine's body is reliably ~750
    // bytes shorter than Chrome's. If content cannot explain that, structure
    // has to -- whole tokens we never emit.
    //
    // The payload is a JSON array of `<key>:<base64>` strings, emitted in a
    // different order every run, so the key is the only thing that lines a token
    // up with its opposite number on the other arm. This reports every key and
    // its length and nothing else: the ciphertext itself compares nothing.
    struct: beacon + `
      let done = false;
      const grab = (s) => {
        if (done || typeof s !== 'string' || s.length < 5000 || s[0] !== '[') return;
        let arr;
        try { arr = JSON.parse(s); } catch (e) { return; }
        if (!Array.isArray(arr)) return;
        done = true;
        const parts = arr.map((e) => {
          const t = String(e);
          const c = t.indexOf(':');
          return (c > 0 && c < 8 ? t.slice(0, c) : '?') + ':' + t.length;
        });
        __send('total=' + s.length + '&count=' + parts.length);
        for (let i = 0; i < parts.length; i += 20) {
          __send('sk=' + i + '&v=' + encodeURIComponent(parts.slice(i, i + 20).join(',')));
        }
      };
      (() => {
        const real = TextEncoder.prototype.encode;
        Object.defineProperty(TextEncoder.prototype, 'encode', {
          configurable: true, writable: true, enumerable: false,
          value: function (input) {
            try { grab(String(input === undefined ? '' : input)); } catch (e) {}
            return real.call(this, input);
          },
        });
      })();
    `,

    // Every plaintext section this engine gets wrong, wrong in Chrome at once,
    // plus a timezone no machine has.
    //
    // Two sections rewritten one at a time each left Chrome ticketed, which is
    // weak evidence -- a station could weigh a dozen answers and shrug off any
    // single one. This asks the question the single knobs cannot: is the verdict
    // a function of the collected content at all? A ticket here says the answers
    // in these sections are not what x-hyatt is judging, and that the gap worth
    // chasing is somewhere other than the values the guard collects.
    'all-ours': beacon + `
      (() => {
        const PX = /^\\d+px(,\\d+px)+$/;
        const isVoices = (s) => s.length > 1000 && s.indexOf(';') > 0 && /^[^,;]+,[^,;]+,[a-z]{2}-[A-Za-z]+,[01],[01];/.test(s);
        const isCodecs = (s) => s.length > 100 && s.slice(0, 12) === '["video/webm';
        const isTz = (s) => s.indexOf('Pacific Daylight Time') !== -1;
        const real = TextEncoder.prototype.encode;
        Object.defineProperty(TextEncoder.prototype, 'encode', {
          configurable: true, writable: true, enumerable: false,
          value: function (input) {
            try {
              const s = String(input === undefined ? '' : input);
              let out = null, what = null;
              if (PX.test(s)) { out = '0px,0px,0px,0px'; what = 'px'; }
              else if (isVoices(s)) { out = ''; what = 'voices'; }
              else if (isCodecs(s)) { out = '[]'; what = 'codecs'; }
              else if (isTz(s)) { out = s.split('Pacific Daylight Time').join('Olympus Mons Time'); what = 'tz'; }
              if (out !== null) {
                __send('sub=' + what + '&from=' + s.length + '&to=' + out.length);
                return real.call(this, out);
              }
            } catch (e) {}
            return real.call(this, input);
          },
        });
      })();
    `,

    // The positive control every negative above depends on.
    //
    // "Chrome kept its ticket" only means something if Chrome can be made to
    // lose one while still posting. break-encoder removes the POST entirely, so
    // it proves the injection bites but not that the oracle can read a refusal.
    // navigator.webdriver is the oldest automation tell there is; a guard that
    // ignores even this is not reading the page's answers, and a guard that
    // catches it gives the scale a zero point.
    'webdriver-true': beacon + `
      __send('knob=webdriver-true');
      try {
        Object.defineProperty(Navigator.prototype, 'webdriver', {
          configurable: true, enumerable: true, get() { return true; },
        });
      } catch (e) {}
    `,

    // Name the source of the `<w>x<h>` tokens.
    //
    // The payload carries tokens keyed by an element size. Chrome's eight land
    // on six distinct sizes; this engine's fifteen land on two, and the two sets
    // do not overlap at all. Fifteen measurements collapsing into two buckets is
    // what a measurement that cannot tell its inputs apart looks like, so it
    // matters which measurement it is. This reports every box the guard asks
    // for, with the element it asked about, so the token keys can be traced back
    // to an API and an element.
    dims: beacon + `
      const seen = [];
      const shot = (src, w, h, el) => {
        try {
          let tag = '?';
          if (el && el.nodeName) {
            tag = el.nodeName.toLowerCase();
            if (el.className && typeof el.className === 'string') tag += '.' + el.className.slice(0, 20);
            // The INLINE font only. Reading the computed style from inside a
            // size getter costs the report: guarded against re-entry and
            // restricted to inputs it still came back with two beacons where
            // this returns fifteen, so whatever the guard's probes take their
            // family from is still an open question -- and the answer is worth
            // having, because Chrome gives them four different heights while
            // this engine gives them one.
            // The raw style attribute and the sizing attributes, which is what
            // finally names the probe. getAttribute touches no layout, so unlike
            // getComputedStyle it costs nothing here -- and the inline style
            // object alone was not enough: it showed a font-size of 100px on
            // every probe while Chrome answered four different boxes for them.
            const raw = el.getAttribute && el.getAttribute('style');
            if (raw) tag += '|style=' + String(raw).replace(/\\s+/g, ' ').slice(0, 90);
            for (const a of ['size', 'width', 'class']) {
              const v = el.getAttribute && el.getAttribute(a);
              if (v) tag += '|' + a + '=' + String(v).slice(0, 24);
            }
          }
          seen.push(src + ':' + Math.round(w) + 'x' + Math.round(h) + '@' + tag);
        } catch (e) {}
      };
      const rect = Element.prototype.getBoundingClientRect;
      Object.defineProperty(Element.prototype, 'getBoundingClientRect', {
        configurable: true, writable: true, enumerable: false,
        value: function () { const r = rect.call(this); try { shot('rect', r.width, r.height, this); } catch (e) {} return r; },
      });
      for (const [proto, wName, hName, src] of [
        [HTMLElement.prototype, 'offsetWidth', 'offsetHeight', 'offset'],
        [Element.prototype, 'clientWidth', 'clientHeight', 'client'],
        [Element.prototype, 'scrollWidth', 'scrollHeight', 'scroll'],
      ]) {
        const dw = Object.getOwnPropertyDescriptor(proto, wName);
        const dh = Object.getOwnPropertyDescriptor(proto, hName);
        if (!dw || !dh) continue;
        Object.defineProperty(proto, wName, { configurable: true, enumerable: dw.enumerable,
          get() { const v = dw.get.call(this); try { shot(src + 'W', v, 0, this); } catch (e) {} return v; } });
        Object.defineProperty(proto, hName, { configurable: true, enumerable: dh.enumerable,
          get() { const v = dh.get.call(this); try { shot(src + 'H', 0, v, this); } catch (e) {} return v; } });
      }
      let sent = false;
      const dump = () => {
        if (sent || !seen.length) return;
        sent = true;
        __send('dims=' + seen.length);
        for (let i = 0; i < seen.length && i < 400; i += 8) {
          setTimeout(() => __send('dk=' + i + '&v=' + encodeURIComponent(seen.slice(i, i + 8).join('|'))), 10 * (i / 8));
        }
      };
      for (const t of [2500, 5000, 9000]) setTimeout(dump, t);
    `,

    // Give Chrome this engine's frozen input box.
    //
    // An `<input>` here measures 153x21 whatever its font-size or font-family
    // is; in Chrome the same element is 1049x121 at font-size 100px and 91x15 at
    // 8px, while a `<span>` control matches both arms exactly. The guard sizes
    // font-metric probes as inputs at font-size 100px, so on this engine every
    // probe returns one box -- which is where the payload's two dimension
    // buckets come from, against Chrome's six.
    //
    // This freezes Chrome's input boxes the same way and asks the only question
    // that matters: does x-hyatt withhold the ticket for it.
    'input-box-frozen': beacon + `
      __send('knob=input-box-frozen');
      const isInput = (el) => { try { return el && el.nodeName === 'INPUT'; } catch (e) { return false; } };
      const FROZEN = { clientWidth: 149, clientHeight: 17, offsetWidth: 153, offsetHeight: 21 };
      for (const [proto, name] of [
        [Element.prototype, 'clientWidth'], [Element.prototype, 'clientHeight'],
        [HTMLElement.prototype, 'offsetWidth'], [HTMLElement.prototype, 'offsetHeight'],
      ]) {
        const d = Object.getOwnPropertyDescriptor(proto, name);
        if (!d || !d.get) continue;
        Object.defineProperty(proto, name, {
          configurable: true, enumerable: d.enumerable,
          get() { return isInput(this) ? FROZEN[name] : d.get.call(this); },
        });
      }
      const rect = Element.prototype.getBoundingClientRect;
      Object.defineProperty(Element.prototype, 'getBoundingClientRect', {
        configurable: true, writable: true, enumerable: false,
        value: function () {
          const r = rect.call(this);
          if (!isInput(this)) return r;
          return new DOMRect(r.x, r.y, 153, 21);
        },
      });
    `,

    // The control `input-box-frozen` depends on. It replaces exactly the same
    // four accessors and getBoundingClientRect, through the same defineProperty
    // calls, and returns the real values. A guard that objects to the hooking
    // itself -- a getter that is no longer native code, a DOMRect built by
    // script -- refuses this too, and then the frozen run proves nothing about
    // the sizes. A ticket here makes the frozen run about the values.
    'input-box-passthru': beacon + `
      __send('knob=input-box-passthru');
      const isInput = (el) => { try { return el && el.nodeName === 'INPUT'; } catch (e) { return false; } };
      for (const [proto, name] of [
        [Element.prototype, 'clientWidth'], [Element.prototype, 'clientHeight'],
        [HTMLElement.prototype, 'offsetWidth'], [HTMLElement.prototype, 'offsetHeight'],
      ]) {
        const d = Object.getOwnPropertyDescriptor(proto, name);
        if (!d || !d.get) continue;
        Object.defineProperty(proto, name, {
          configurable: true, enumerable: d.enumerable,
          get() { return isInput(this) ? d.get.call(this) : d.get.call(this); },
        });
      }
      const rect = Element.prototype.getBoundingClientRect;
      Object.defineProperty(Element.prototype, 'getBoundingClientRect', {
        configurable: true, writable: true, enumerable: false,
        value: function () {
          const r = rect.call(this);
          if (!isInput(this)) return r;
          return new DOMRect(r.x, r.y, r.width, r.height);
        },
      });
    `,

    // Which font families the guard names, read off the WRITE path.
    //
    // `dims` reports the guard's probes as `<input>` at font-size 100px with no
    // inline font-family at all, yet Chrome answers four different heights for
    // them and this engine answers one -- so the family arrives some other way.
    // Reading it back is what failed: `getComputedStyle` from inside a size
    // getter re-enters the same hooks and costs the report, guarded or not.
    //
    // So hook the setters instead. A font can only be declared through one of
    // these five, none of which touches layout, so recording them is free:
    // the `font-family` and `font` accessors on CSSStyleDeclaration, `cssText`,
    // `setProperty`, and `setAttribute('style', ...)`. Whatever the guard uses,
    // one of these sees the literal string it asked for.
    fontset: beacon + `
      // Reported as it happens, one beacon per write, rather than batched behind
      // a timer. Batching lost most of them twice over: the first dump latched
      // on the earliest write and locked out everything after it, and the
      // passing arm navigates into the site and kills the pending timers anyway.
      // Newlines are stripped so one write stays one line on the way out.
      let nth = 0;
      const note = (how, value) => {
        try {
          // Truncate, never drop. Dropping anything over 200 characters threw
          // away exactly the writes worth having: a font-family list naming a
          // dozen faces is longer than that.
          const s = String(value).replace(/\\s+/g, ' ');
          const body = s.length > 700 ? s.slice(0, 700) + '<TRUNC:' + s.length + '>' : s;
          __send('fw=' + (nth++) + '&how=' + encodeURIComponent(how) + '&v=' + encodeURIComponent(body));
        } catch (e) {}
      };
      const decl = window.CSSStyleDeclaration && CSSStyleDeclaration.prototype;
      for (const name of ['fontFamily', 'font']) {
        const d = decl && Object.getOwnPropertyDescriptor(decl, name);
        if (!d || !d.set) continue;
        Object.defineProperty(decl, name, {
          configurable: true, enumerable: d.enumerable,
          get() { return d.get.call(this); },
          set(v) { note(name, v); return d.set.call(this, v); },
        });
      }
      const cssTextDesc = decl && Object.getOwnPropertyDescriptor(decl, 'cssText');
      if (cssTextDesc && cssTextDesc.set) {
        Object.defineProperty(decl, 'cssText', {
          configurable: true, enumerable: cssTextDesc.enumerable,
          get() { return cssTextDesc.get.call(this); },
          set(v) { if (String(v).indexOf('font') !== -1) note('cssText', v); return cssTextDesc.set.call(this, v); },
        });
      }
      if (decl && typeof decl.setProperty === 'function') {
        const real = decl.setProperty;
        decl.setProperty = function (prop, value, prio) {
          try { if (String(prop).indexOf('font') !== -1) note('setProperty:' + prop, value); } catch (e) {}
          return real.call(this, prop, value, prio);
        };
      }
      const setAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        try { if (String(name) === 'style' && String(value).indexOf('font') !== -1) note('attr', value); } catch (e) {}
        return setAttr.call(this, name, value);
      };
      // A rule in a stylesheet is the sixth way, and the only one left that can
      // give a dozen probes a dozen different families without touching any
      // element's own style.
      if (window.CSSStyleSheet && CSSStyleSheet.prototype.insertRule) {
        const real = CSSStyleSheet.prototype.insertRule;
        CSSStyleSheet.prototype.insertRule = function (rule, index) {
          try { if (String(rule).indexOf('font') !== -1) note('insertRule', rule); } catch (e) {}
          return real.call(this, rule, index);
        };
      }
      // Markup is the path none of the setters above can see: an element built
      // from an HTML string carries its style attribute without setAttribute
      // ever being called, and a <style> filled by innerHTML never touches
      // textContent. Chrome's probes come out with four different line boxes
      // and none of the setter hooks explain it, so this is where to look.
      for (const [proto, name] of [[Element.prototype, 'innerHTML'], [Element.prototype, 'outerHTML']]) {
        const d = Object.getOwnPropertyDescriptor(proto, name);
        if (!d || !d.set) continue;
        Object.defineProperty(proto, name, {
          configurable: true, enumerable: d.enumerable,
          get() { return d.get.call(this); },
          set(v) { try { if (String(v).indexOf('font') !== -1) note(name, v); } catch (e) {} return d.set.call(this, v); },
        });
      }
      if (Element.prototype.insertAdjacentHTML) {
        const real = Element.prototype.insertAdjacentHTML;
        Element.prototype.insertAdjacentHTML = function (pos, html) {
          try { if (String(html).indexOf('font') !== -1) note('insertAdjacentHTML', html); } catch (e) {}
          return real.call(this, pos, html);
        };
      }
      if (document.write) {
        const real = document.write;
        document.write = function (...a) {
          try { const s = a.join(''); if (s.indexOf('font') !== -1) note('document.write', s); } catch (e) {}
          return real.apply(this, a);
        };
      }
      // ...and a <style> element's own text is the seventh.
      const textDesc = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent');
      if (textDesc && textDesc.set) {
        Object.defineProperty(Node.prototype, 'textContent', {
          configurable: true, enumerable: textDesc.enumerable,
          get() { return textDesc.get.call(this); },
          set(v) {
            try {
              if (this && this.nodeName === 'STYLE' && String(v).indexOf('font') !== -1) note('styleText', v);
            } catch (e) {}
            return textDesc.set.call(this, v);
          },
        });
      }

    `,

    // The payload's `h:` tokens, whole.
    //
    // Both arms emit 449 tokens, and after the box work the keys line up -- but
    // this one does not: Chrome sends ONE `h:` token of 7 characters and this
    // engine sends FOUR totalling 396. Four short records where a passing
    // browser has one is the shape of something being reported rather than
    // measured, and this engine is separately known to hit Kasada's own error
    // endpoint on about half its runs where Chrome never does. Short enough to
    // send whole, so the guess stops here and the text decides.
    'htokens': beacon + `
      let done = false;
      const grab = (s) => {
        if (done || typeof s !== 'string' || s.length < 5000 || s[0] !== '[') return;
        let arr;
        try { arr = JSON.parse(s); } catch (e) { return; }
        if (!Array.isArray(arr)) return;
        done = true;
        let n = 0;
        for (const e of arr) {
          const t = String(e);
          const c = t.indexOf(':');
          if (c <= 0 || c >= 8) continue;
          const key = t.slice(0, c);
          if (key !== 'h' && key !== 'g') continue;
          const body = t.length > 600 ? t.slice(0, 600) + '<TRUNC:' + t.length + '>' : t;
          const i = n++;
          setTimeout(() => __send('ht=' + i + '&k=' + key + '&v=' + encodeURIComponent(body)), 12 * i);
        }
        __send('htcount=' + n);
      };
      (() => {
        const real = TextEncoder.prototype.encode;
        Object.defineProperty(TextEncoder.prototype, 'encode', {
          configurable: true, writable: true, enumerable: false,
          value: function (input) {
            try { grab(String(input === undefined ? '' : input)); } catch (e) {}
            return real.call(this, input);
          },
        });
      })();
    `,

    // Give Chrome's trap log this engine's [[Has]] signature.
    //
    // The guard hands a Proxy to Web API constructors and records the traps.
    // Chrome reads a dictionary member with [[Get]]; this engine asks [[Has]]
    // first, in the IDL file's declaration order rather than the alphabetical
    // one WebIDL requires. Chrome's binding layer cannot be changed from here,
    // so this replays our exact sequence against the same object before handing
    // it to the real constructor -- additive, so Chrome's own reads still
    // happen and the only difference is our tell appearing alongside them.
    //
    // Losing the ticket here says the guard weighs the trap log. Keeping it
    // says this is not what x-hyatt is holding against us, whatever else it is.
    'has-probe': beacon + `
      __send('knob=has-probe');
      const REQ = ['method','headers','body','cache','credentials','redirect','signal',
                   'priority','duplex','mode','referrer','referrerPolicy','integrity','keepalive'];
      const EVT = ['bubbles','cancelable','composed','detail','view','data','dataTransfer',
                   'inputType','isComposing'];
      const replay = (init, names) => {
        if (!init || (typeof init !== 'object' && typeof init !== 'function')) return;
        for (const n of names) { try { Reflect.has(init, n); } catch (e) {} }
      };
      const wrap = (name, names) => {
        const Real = window[name];
        if (typeof Real !== 'function') return;
        function Wrapped(...args) {
          try { replay(args[1], names); } catch (e) {}
          return Reflect.construct(Real, args, new.target || Wrapped);
        }
        Wrapped.prototype = Real.prototype;
        try { Object.defineProperty(Wrapped, 'name', { value: name, configurable: true }); } catch (e) {}
        try { window[name] = Wrapped; } catch (e) {}
      };
      wrap('Request', REQ);
      wrap('InputEvent', EVT);
    `,

    // The control `has-probe` needs: the same two constructors replaced through
    // the same wrapper, replaying nothing. A guard that objects to a Request
    // whose constructor is no longer native code refuses this too, and then the
    // probe run proves nothing about the trap log.
    'has-probe-passthru': beacon + `
      __send('knob=has-probe-passthru');
      const wrap = (name) => {
        const Real = window[name];
        if (typeof Real !== 'function') return;
        function Wrapped(...args) { return Reflect.construct(Real, args, new.target || Wrapped); }
        Wrapped.prototype = Real.prototype;
        try { Object.defineProperty(Wrapped, 'name', { value: name, configurable: true }); } catch (e) {}
        try { window[name] = Wrapped; } catch (e) {}
      };
      wrap('Request');
      wrap('InputEvent');
    `,

    // Take away the 36 globals Chrome has and this engine does not.
    //
    // Measured off an about:blank iframe realm on both arms: Chrome has 1237
    // own names there and this engine 1201, with none the other way round. The
    // 36 are the newest platform surfaces -- Temporal, Observable/Subscriber,
    // the shared-storage family, fenced frames, the on-device model APIs.
    //
    // This is the one capability difference that CAN be tested in the right
    // direction: unlike the binding layer's [[Get]] behaviour, a global can be
    // deleted from a page. Chrome losing the ticket here names the tell and the
    // fix; keeping it rules the whole set out at once.
    'drop-36-globals': beacon + `
      const NAMES = ["BarcodeDetector", "CloseWatcher", "CreateMonitor", "DigitalCredential", "DocumentPictureInPicture", "DocumentPictureInPictureEvent", "Fence", "FencedFrameConfig", "FetchLaterResult", "FileSystemObserver", "HTMLFencedFrameElement", "IdentityCredentialError", "IdentityProvider", "LanguageDetector", "LanguageModel", "Observable", "PressureObserver", "PressureRecord", "RestrictionTarget", "SharedStorage", "SharedStorageAppendMethod", "SharedStorageClearMethod", "SharedStorageDeleteMethod", "SharedStorageModifierMethod", "SharedStorageSetMethod", "SharedStorageWorklet", "Subscriber", "Summarizer", "Temporal", "Translator", "WebSocketError", "WebSocketStream", "documentPictureInPicture", "fence", "fetchLater", "sharedStorage"];
      let gone = 0;
      for (const n of NAMES) {
        try {
          if (n in window) { delete window[n]; }
          if (n in window) { Object.defineProperty(window, n, { configurable: true, get() { return undefined; } }); }
          if (!(n in window)) gone++;
        } catch (e) {}
      }
      __send('knob=drop-36-globals&dropped=' + gone + '&of=' + NAMES.length);
    `,

    // The control `drop-36-globals` needs if it fires: the same deletion loop
    // over 36 globals BOTH arms already have, so a guard that objects to a
    // thinned global object rather than to these particular names refuses this
    // one too.
    'drop-36-control': beacon + `
      const NAMES = ["AbsoluteOrientationSensor","Accelerometer","AmbientLightSensor","BatteryManager",
        "Gyroscope","LinearAccelerationSensor","Magnetometer","OrientationSensor",
        "RelativeOrientationSensor","Sensor","SensorErrorEvent","GravitySensor",
        "USB","USBAlternateInterface","USBConfiguration","USBConnectionEvent","USBDevice",
        "USBEndpoint","USBInTransferResult","USBInterface","USBIsochronousInTransferPacket",
        "USBIsochronousInTransferResult","USBIsochronousOutTransferPacket",
        "USBIsochronousOutTransferResult","USBOutTransferResult","Serial","SerialPort",
        "HID","HIDDevice","HIDConnectionEvent","HIDInputReportEvent","Bluetooth",
        "BluetoothDevice","BluetoothRemoteGATTServer","BluetoothRemoteGATTService","BluetoothUUID"];
      let gone = 0;
      for (const n of NAMES) {
        try {
          if (n in window) { delete window[n]; }
          if (n in window) { Object.defineProperty(window, n, { configurable: true, get() { return undefined; } }); }
          if (!(n in window)) gone++;
        } catch (e) {}
      }
      __send('knob=drop-36-control&dropped=' + gone + '&of=' + NAMES.length);
    `,

    // Does the guard's own code throw in this engine?
    //
    // This engine reaches Kasada's error endpoint (reporting.cdndex.io/error) on
    // about half its runs and Chrome never does. That was written off once with
    // "both runs are 429 anyway", which is bad reasoning: it says the errors do
    // not separate OUR passing runs from OUR failing ones, not that they do not
    // separate us from Chrome. An exception part-way through the challenge would
    // leave the computed answer incomplete, and no amount of correct fingerprint
    // values would then earn a ticket -- which is the shape every negative so far
    // has left behind.
    //
    // Catches all four routes an exception can surface by: window.onerror,
    // unhandledrejection, and the console's error/warn channels.
    errors: beacon + `
      let n = 0;
      const shout = (how, msg, extra) => {
        try {
          const s = String(msg).replace(/\s+/g, ' ').slice(0, 300);
          __send('err=' + (n++) + '&how=' + how + '&m=' + encodeURIComponent(s) +
                 (extra ? '&x=' + encodeURIComponent(String(extra).slice(0, 200)) : ''));
        } catch (e) {}
      };
      window.addEventListener('error', (e) => {
        shout('onerror', (e && e.message) || 'error',
              e && e.error && e.error.stack ? e.error.stack : (e && e.filename) + ':' + (e && e.lineno));
      }, true);
      window.addEventListener('unhandledrejection', (e) => {
        const r = e && e.reason;
        shout('reject', (r && (r.message || r)) || 'rejection', r && r.stack);
      }, true);
      for (const level of ['error', 'warn']) {
        try {
          const real = console[level];
          console[level] = function (...a) {
            try { shout('console.' + level, a.map((x) => { try { return x && x.stack ? x.stack : x; } catch (e) { return '?'; } }).join(' ')); } catch (e) {}
            return real.apply(this, a);
          };
        } catch (e) {}
      }
      __send('errors=armed');
    `,

    // Hold the /tl POST back until Chrome's moment.
    //
    // Measured on x-hyatt, three runs each: this engine posts at 916, 1093 and
    // 1478ms after the navigation, Chrome at 1932, 2000 and 3016ms. The ranges
    // do not overlap, and the 429 document arrives at the same time on both --
    // ~300-440ms -- so it is the guard's own work that is twice as fast here.
    //
    // Kasada weighs timing, and this is the one thing the server sees that has
    // never been tested. Delaying the send moves ARRIVAL only: whatever the
    // payload says about its own schedule is already sealed by then. So a
    // ticket here means the server timed the request, and no ticket leaves the
    // stronger question -- the guard's internal clock -- for `slow-clock`.
    'delay-tl': beacon + `
      const DELAY = 1100;
      const openReal = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url, ...rest) {
        try { this.__b84url = String(url); } catch (e) {}
        return openReal.call(this, method, url, ...rest);
      };
      const sendReal = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function (...args) {
        let isTl = false;
        try { const u = String(this.__b84url || '').split('?')[0]; isTl = u.slice(-3) === '/tl'; } catch (e) {}
        if (!isTl) return sendReal.apply(this, args);
        __send('delaying=' + DELAY);
        setTimeout(() => { try { sendReal.apply(this, args); } catch (e) {} }, DELAY);
        return undefined;
      };
      const fetchReal = window.fetch;
      if (typeof fetchReal === 'function') {
        window.fetch = function (input, init) {
          let u = '';
          try { u = String(typeof input === 'string' ? input : (input && input.url) || ''); } catch (e) {}
          if (u.split('?')[0].slice(-3) !== '/tl') return fetchReal.call(this, input, init);
          __send('delaying-fetch=' + DELAY);
          return new Promise((res, rej) => setTimeout(() => {
            try { fetchReal.call(window, input, init).then(res, rej); } catch (e) { rej(e); }
          }, DELAY));
        };
      }
      __send('knob=delay-tl');
    `,

    // Read every section the guard feeds into its payload, whole, on either arm.
    // Descended from probes/inject-b55-funnels.js, which captured the same
    // funnels but only ever compared *lengths* -- the sections' own text was
    // never diffed across the arms, and that text is the list of answers the
    // two engines disagree on.
    //
    // TextEncoder.encode is the funnel that matters: its argument is a payload
    // section in plaintext, before the encoding that turns the body into
    // ciphertext. Chunks go out as image query strings because Runtime.enable
    // is off limits, and each chunk carries its section index and offset so the
    // sections can be reassembled in order on the other side.
    funnels: beacon + `
      const rec = [];
      const hook = (proto, name, tag, pick) => {
        if (!proto || typeof proto[name] !== 'function') return;
        const real = proto[name];
        try {
          Object.defineProperty(proto, name, {
            configurable: true, writable: true, enumerable: false,
            value: function (...args) {
              try {
                let s = pick(args, this);
                s = typeof s === 'string' ? s : String(s);
                // The document this was read in. The passing arm navigates into
                // the site and the site has its own TextEncoder traffic, so a
                // section captured there is not the guard's and comparing it
                // against the refused arm's -- which never leaves the 429 --
                // compares two different pages.
                rec.push({ tag, val: s, href: location.href });
              } catch (e) {}
              return real.apply(this, args);
            },
          });
        } catch (e) {}
      };
      hook(window.TextEncoder && TextEncoder.prototype, 'encode', 'enc', (a) => (a[0] === undefined ? '' : a[0]));
      hook(window, 'btoa', 'btoa', (a) => a[0]);

      let reported = false;
      const report = () => {
        if (reported || !rec.length) return;
        reported = true;
        __send('sum=' + encodeURIComponent(rec.map((r, i) => i + ':' + r.tag + ':' + r.val.length).join(',')).slice(0, 1800));
        // The serialised payload itself is ciphertext; a prefix of it compares
        // nothing. Every other section is plaintext and is sent whole.
        let k = 0;
        rec.forEach((r, i) => {
          const cap = r.val.length > 5000 ? 600 : r.val.length;
          for (let off = 0; off < cap; off += 600) {
            const q = 'i=' + i + '&t=' + r.tag + '&o=' + off + '&n=' + r.val.length +
                      '&d=' + encodeURIComponent(r.href) +
                      '&v=' + encodeURIComponent(r.val.slice(off, off + 600));
            setTimeout(() => __send(q), 15 * k++);
          }
        });
      };
      // The refused arm sits on its 429; the passing arm navigates into the site
      // as soon as the guard clears and takes this document's pending timers
      // with it. Report early and repeatedly.
      for (const t of [2000, 3500, 6000, 10000]) setTimeout(report, t);
    `,
};
