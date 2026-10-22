// readyState of what DOMParser.parseFromString hands back, per MIME type,
// well-formed and not, next to documents built by DOMImplementation.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-domparser-readystate.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:18765/p/page.html'
(() => {
  const p = new DOMParser();
  const out = {};
  for (const t of ['text/html', 'text/xml', 'application/xml', 'application/xhtml+xml', 'image/svg+xml']) {
    const ok = t === 'image/svg+xml' ? '<svg xmlns="http://www.w3.org/2000/svg"/>'
      : t === 'application/xhtml+xml' ? '<html xmlns="http://www.w3.org/1999/xhtml"><body/></html>' : '<a><b/></a>';
    out[t] = p.parseFromString(ok, t).readyState;
    out[t + ' bad'] = p.parseFromString('<a><b></a>', t).readyState;
  }
  out.createDocument = document.implementation.createDocument(null, 'a').readyState;
  out.createDocumentNs = document.implementation.createDocument('http://www.w3.org/1999/xhtml', 'html').readyState;
  out.createHTMLDocument = document.implementation.createHTMLDocument('').readyState;
  out.newDocument = new Document().readyState;
  return out;
})()
