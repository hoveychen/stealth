// What XMLHttpRequest hands back as a document: responseXML of an XML
// resource (well-formed and not), responseType='document' of an HTML one,
// a text/xml and an SVG one, and one reached through a redirect. Page and
// resources from xhr-document-server.py:
//
//   python3 tools/fingerprint/probes/xhr-document-server.py 18767 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-xhr-document.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:18767/p/page.html'
(async () => {
  const xhr = (url, type) => new Promise((res) => {
    const x = new XMLHttpRequest();
    x.open('GET', url);
    if (type) x.responseType = type;
    x.onloadend = () => res(x);
    x.send();
  });
  const read = (d) => d === null ? null : ({
    ctor: d.constructor.name, readyState: d.readyState, URL: d.URL, documentURI: d.documentURI,
    baseURI: d.baseURI, contentType: d.contentType, characterSet: d.characterSet,
    compatMode: d.compatMode, title: d.title, root: d.documentElement && d.documentElement.nodeName,
    aHref: d.querySelector('a[href]') ? d.querySelector('a[href]').href : null,
    defaultView: d.defaultView === null ? null : typeof d.defaultView,
    hasFocus: (() => { try { return d.hasFocus(); } catch (e) { return String(e); } })(),
    lastModifiedLen: d.lastModified.length, referrer: d.referrer, cookie: d.cookie, domain: d.domain,
    visibilityState: d.visibilityState, hidden: d.hidden,
    scripts: d.scripts ? d.scripts.length : null,
  });
  const out = {};
  out.xml = read((await xhr('/x/doc.xml')).responseXML);
  out.xmlText = read((await xhr('/x/text.xml')).responseXML);
  out.svg = read((await xhr('/x/pic.svg')).responseXML);
  out.redirect = read((await xhr('/x/redir')).responseXML);
  out.htmlRedirectDoc = read((await xhr('/x/redir', 'document')).response);
  out.xmlBad = read((await xhr('/x/bad.xml')).responseXML);
  out.xmlAsDocument = read((await xhr('/x/doc.xml', 'document')).response);
  out.htmlResponseXML = read((await xhr('/x/doc.html')).responseXML);
  out.htmlDocument = read((await xhr('/x/doc.html', 'document')).response);
  out.scriptRan = window.__ran || 0;
  return out;
})()
