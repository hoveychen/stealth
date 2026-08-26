// How wide is the CSS number serialisation difference the guard questions
// turned up?
//
// x-hyatt's Kasada script binary-searches devicePixelRatio with 314 media
// queries and reads `.media` back off each MediaQueryList. Chrome answers
// `(min-resolution: 1.01562dppx)` where this engine answers
// `1.01563dppx` -- six significant digits either way, but Chrome breaks the tie
// to even and this engine breaks it away from zero. For `<ratio>` this engine
// does not round at all: `1.626953125 / 1` against Chrome's `1.62695 / 1`.
//
// A tie-break rule is not a media-query fact, so the question is which other
// surfaces show it. Every value below is a half-way case at the sixth
// significant digit, asked of every place a number crosses back out to JS:
// the media-query serialiser, a style declaration's own text, the computed
// value, and the Typed OM. Nothing here depends on the machine -- no screen
// size, no devicePixelRatio -- so the two arms are comparable whatever they
// are running on.
(() => {
  const out = {};
  const call = (label, fn) => {
    try {
      const v = fn();
      out[label] = v === undefined ? 'undefined' : v === null ? 'null' : String(v);
    } catch (e) { out[label] = (e.name || 'Error') + ': ' + e.message; }
  };

  // Half-way at the sixth significant digit, so round-to-even and
  // round-away-from-zero disagree, plus a few that are not ties as controls.
  const HALVES = [
    '1.015625', '1.421875', '1078.125', '0.9765625', '38.28125', '97.65625',
    '101.5625', '1.0000152587890625', '12345.65', '1234565', '0.000101562500001',
  ];
  const CONTROLS = ['1.59765625', '1.5994873046875', '3.14159265358979', '100', '0.5'];

  // 1. the media-query serialiser -- the surface Kasada actually read.
  for (const n of [...HALVES, ...CONTROLS]) {
    call('mq min-width ' + n, () => matchMedia('(min-width: ' + n + 'px)').media);
    call('mq min-resolution ' + n, () => matchMedia('(min-resolution: ' + n + 'dppx)').media);
    call('mq min-aspect-ratio ' + n, () => matchMedia('(min-aspect-ratio: ' + n + ')').media);
  }

  // 2. a declaration's own text, set and read back without layout in the way.
  const el = document.createElement('div');
  document.documentElement.appendChild(el);
  for (const n of [...HALVES, ...CONTROLS]) {
    call('style width ' + n, () => { el.style.width = n + 'px'; return el.style.width; });
    call('style opacity ' + n, () => { el.style.opacity = n; return el.style.opacity; });
    call('style rotate ' + n, () => { el.style.rotate = n + 'deg'; return el.style.rotate; });
    call('cssText width ' + n, () => { el.style.cssText = 'width:' + n + 'px'; return el.style.cssText; });
  }

  // 3. the computed value, on properties that do not get re-quantised by
  // layout (an inherited length that nothing lays out, and a unitless number).
  for (const n of [...HALVES, ...CONTROLS]) {
    call('computed letter-spacing ' + n, () => {
      el.style.letterSpacing = n + 'px';
      return getComputedStyle(el).letterSpacing;
    });
    call('computed opacity ' + n, () => {
      el.style.opacity = n;
      return getComputedStyle(el).opacity;
    });
  }

  // 4. the Typed OM, which hands the number back as a number rather than text.
  for (const n of HALVES) {
    call('CSSUnitValue ' + n, () => (self.CSSUnitValue ? new CSSUnitValue(Number(n), 'px').toString() : 'no CSSUnitValue'));
    call('CSS.px ' + n, () => (self.CSS && CSS.px ? CSS.px(Number(n)).toString() : 'no CSS.px'));
  }

  // 5. what JS itself would print, as the baseline both arms must agree on --
  // if these differ the finding is V8's, not the CSS serialiser's.
  for (const n of HALVES) call('Number ' + n, () => String(Number(n)));
  for (const n of HALVES) call('toPrecision6 ' + n, () => Number(n).toPrecision(6));

  el.remove();
  return out;
})()
