// Documents with no browsing context, read on a headed Chrome. Image fetches
// are judged from the access log of an image server on :18772
// (python3 -m http.server 18772 in a directory holding a file named dummy).
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-frameless-doc-flags.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:<port>/page.html'
(async () => {
  const out = {};
  const safe = (f) => { try { const v = f(); return v === undefined ? 'undefined' : v; } catch (e) { return 'throw:' + e.name; } };
  const IMG = 'http://127.0.0.1:18772/dummy?case=';
  const docs = {
    page: document,
    inert: document.createElement('template').content.ownerDocument,
    createHTML: document.implementation.createHTMLDocument('t'),
    createHTMLNoDoctype: (() => { const d = document.implementation.createHTMLDocument('t'); d.doctype.remove(); return d; })(),
    createDoc: document.implementation.createDocument(null, 'r'),
    domparser: new DOMParser().parseFromString('<!doctype html><p>x', 'text/html'),
    domparserQuirks: new DOMParser().parseFromString('<p>x', 'text/html'),
    domparserXML: new DOMParser().parseFromString('<r/>', 'application/xml'),
    newDocument: new Document(),
  };
  for (const [k, d] of Object.entries(docs)) {
    out[k] = {
      compatMode: safe(() => d.compatMode),
      fullscreenEnabled: safe(() => d.fullscreenEnabled),
      pictureInPictureEnabled: safe(() => d.pictureInPictureEnabled),
    };
    if (k === 'page') continue;
    const img = d.createElementNS('http://www.w3.org/1999/xhtml', 'img');
    img.src = IMG + k + '-created';
    const tpl = document.createElement('div');
    if (d.body) { const i2 = d.createElement('img'); d.body.appendChild(i2); i2.src = IMG + k + '-connected'; }
  }
  // parsed-in img in a DOMParser doc
  new DOMParser().parseFromString('<img src="' + IMG + 'domparser-parsed">', 'text/html');
  const t = document.createElement('template');
  t.innerHTML = '<img src="' + IMG + 'template-parsed">';
  // page control: disconnected img in the page document
  const pi = document.createElement('img'); pi.src = IMG + 'page-disconnected';
  await new Promise((r) => setTimeout(r, 800));
  out.done = true;
  return out;
})()
