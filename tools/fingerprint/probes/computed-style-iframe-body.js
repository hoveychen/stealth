// The read the Cloudflare widget makes, reproduced offline.
//
// In `results/p5-oracle.json` the widget's 30 902-character `JSON.stringify`
// record is a computed style, and the `installed` line before it says the realm
// is an about:blank child: the widget dumps `getComputedStyle` over the <body>
// of a 0x0 about:blank iframe. This does exactly that, so the result can be
// compared against the oracle's recorded bytes without another sitting on the
// station -- which is the only way to check the reading when neither arm clears:
//
//   node tools/fingerprint/run-page-probe.mjs \
//       tools/fingerprint/probes/computed-style-iframe-body.js > /tmp/ours.json
//   node -e '
//     const o = require("./tools/fingerprint/results/p5-oracle.json");
//     const rec = o.records.find(r => r.k === "JSON.stringify" && r.a.n === 30902);
//     console.log(JSON.stringify(require("/tmp/ours.json")) === rec.a.v);
//   '
//
// The iframe is 0x0 because that is what Chrome's answers say it was: `width`
// and `height` come back `0px` and both origins `0px 0px`, which a hidden or a
// default-sized iframe does not produce (an about:blank document is in quirks
// mode, so its body fills the viewport rather than collapsing to its content).
(() => {
  const f = document.createElement('iframe');
  f.width = '0';
  f.height = '0';
  document.body.appendChild(f);
  const d = f.contentDocument;
  return JSON.parse(JSON.stringify(d.defaultView.getComputedStyle(d.body)));
})()
