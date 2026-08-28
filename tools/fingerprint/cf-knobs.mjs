// Knobs for cf-knob.mjs. Each is a source string injected into every document,
// on every target, before anything on the page runs.
//
// The first three are controls and they earn their place. A knob that changes
// nothing and a knob that never ran look identical from the wire, so nothing
// here is interpretable until `alive` has been seen to report from BOTH
// documents -- the challenge page and the widget's cross-origin frame -- and
// until one knob has been seen to actually cost the ticket.
const beacon = `
  const __send = (q) => { try { new Image().src = '/__cfknob?' + q; } catch (e) {} };
  const __where = () => {
    try { return location.host + (window.top === window ? '/top' : '/frame'); }
    catch (e) { return 'cross-origin/frame'; }
  };
`;

export const CF_KNOBS = {
    // Control 1: nothing injected at all. The baseline the others are read
    // against -- if this loses the ticket, the station moved and no reading in
    // the session means anything.
    none: '',

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
};
