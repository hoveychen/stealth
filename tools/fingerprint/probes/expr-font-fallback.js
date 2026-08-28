// Does an unavailable font family fall back to the generic, byte for byte?
//
// The cf-scrapingcourse widget ships a candidate font list and keeps the ones
// it detects; `report-payload` caught the result on the wire. Chrome answers
// with six names, all of them macOS fonts. This engine answers with about
// fifty, including `Adwaita Sans` (GNOME) and `Aldhabi` (Windows) -- families
// that are not installed on any Mac. Nothing in src/ hardcodes those names, so
// they are not being claimed, they are being *measured*: the detector renders a
// string in `"<candidate>", <generic>` and in `<generic>` alone and calls the
// family present when the widths differ.
//
// So the question is not "which fonts do we have" but "does an unknown family
// measure the same as the generic it falls back to". This probe asks it three
// ways, because the standard detector uses three generic baselines.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-font-fallback.js --url https://example.com --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-font-fallback.js --url https://example.com
(() => {
  const SAMPLE = 'mmmmmmmmmmlli';
  const GENERICS = ['monospace', 'sans-serif', 'serif'];
  const CANDIDATES = [
    // Installed on this Mac, and Chrome does report these.
    'Geneva', 'Luminari', 'Apple Symbols', 'Galvji',
    // Real fonts, but from other platforms -- no Mac has them, and this engine
    // was measured claiming both.
    'Adwaita Sans', 'Adwaita Mono', 'Aldhabi', 'Arimo', 'Bahnschrift',
    // Not a font anywhere.
    'NoSuchFamilyQZX', 'ZZZZ Definitely Absent',
  ];

  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;left:-9999px;top:-9999px;white-space:nowrap;';
  document.body.appendChild(host);

  const width = (family) => {
    const s = document.createElement('span');
    s.style.cssText = 'font-size:72px;white-space:nowrap;font-family:' + family;
    s.textContent = SAMPLE;
    host.appendChild(s);
    const w = [s.offsetWidth, Math.round(s.getBoundingClientRect().width * 1000) / 1000];
    host.removeChild(s);
    return w;
  };

  const out = { sample: SAMPLE };
  const base = {};
  for (const g of GENERICS) {
    base[g] = width(g);
    out['base.' + g] = base[g];
  }

  // The detector's own verdict: present iff the width moved off the generic.
  for (const c of CANDIDATES) {
    const per = {};
    let detected = false;
    for (const g of GENERICS) {
      const w = width('"' + c + '",' + g);
      per[g] = w;
      if (w[0] !== base[g][0] || w[1] !== base[g][1]) detected = true;
    }
    out['font.' + c] = { widths: per, detectedAsPresent: detected };
  }

  // And the two APIs a detector might use instead of measuring.
  out['fonts.check'] = {};
  for (const c of CANDIDATES.concat(['monospace'])) {
    try { out['fonts.check'][c] = document.fonts.check('72px "' + c + '"'); }
    catch (e) { out['fonts.check'][c] = 'threw:' + e.name; }
  }
  try {
    const cv = document.createElement('canvas').getContext('2d');
    out['measureText'] = {};
    for (const f of GENERICS.concat(CANDIDATES.map((c) => '"' + c + '",monospace'))) {
      cv.font = '72px ' + f;
      out['measureText'][f] = [cv.font, Math.round(cv.measureText(SAMPLE).width * 1000) / 1000];
    }
  } catch (e) { out['measureText'] = 'threw:' + e.name; }

  document.body.removeChild(host);
  return out;
})()
