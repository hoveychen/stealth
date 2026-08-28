// Does a `local()` font source resolve for a family that is not installed?
//
// This is the mechanism behind the cf-scrapingcourse font span. The widget
// builds its installed-font list with
//
//     new FontFace(name, 'local("Candidate")').load()
//
// and keeps the candidates whose promise resolves. On this Mac, Chrome keeps
// six of the fifty-four candidates and rejects the rest with NetworkError;
// this engine resolves ALL fifty-four, so it reports Aldhabi, Bahnschrift,
// Gadugi and Segoe Fluent Icons (Windows) alongside Adwaita Sans, Cantarell,
// DejaVu Sans and Ubuntu (GNOME) -- families no Mac has, and a combination no
// real machine has.
//
// Four other candidate mechanisms were ruled out first, each because the two
// arms answer byte for byte the same: span width against all three generic
// baselines, canvas and OffscreenCanvas measureText, every field of
// TextMetrics, document.fonts.check, and queryLocalFonts. See
// expr-font-fallback.js for that comparison.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-fontface-local.js --url https://example.com --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-fontface-local.js --url https://example.com
//
// Cloudflare does not appear to weigh the resulting list -- handing Chrome this
// engine's answer with the `all-local-fonts` knob kept the ticket 2/3 against a
// 3/3 baseline -- so this is a fidelity defect rather than a door.
(async () => {
  const out = {};
  const INSTALLED = ['Geneva', 'Luminari', 'Apple Symbols', 'PingFang HK Light'];
  const ABSENT = ['Aldhabi', 'Bahnschrift', 'Gadugi', 'Segoe Fluent Icons',
    'Adwaita Sans', 'Cantarell', 'DejaVu Sans', 'Ubuntu', 'NoSuchFamilyQZX'];

  out.typeofFontFace = typeof window.FontFace;
  out.load = {};
  for (const n of INSTALLED.concat(ABSENT)) {
    try {
      const f = new FontFace('probe-' + n.replace(/\W/g, ''), 'local("' + n + '")');
      await f.load();
      out.load[n] = 'loaded:' + f.status;
    } catch (e) { out.load[n] = 'rejected:' + (e && e.name); }
  }

  // A FontFace that has not been loaded yet is `unloaded` -- adding it to the
  // set does not load it. This engine reports `loaded` straight away, which is
  // the same defect seen from the other side.
  out.addedStatus = {};
  for (const n of INSTALLED.slice(0, 2).concat(ABSENT.slice(0, 1))) {
    try {
      const f = new FontFace('probe2', 'local("' + n + '")');
      document.fonts.add(f);
      out.addedStatus[n] = f.status;
      document.fonts.delete(f);
    } catch (e) { out.addedStatus[n] = 'threw:' + (e && e.name); }
  }

  // The two counts the widget's span is built from, so a fix can be checked
  // against the number that actually goes on the wire.
  out.installedResolved = INSTALLED.filter((n) => String(out.load[n]).startsWith('loaded')).length;
  out.absentResolved = ABSENT.filter((n) => String(out.load[n]).startsWith('loaded')).length;
  return out;
})()
