(() => {
  const out = [];
  const rec = (label, value) => out.push([label, JSON.stringify(value)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };
  const P = (doc) => (sel) => { try { return doc.querySelectorAll(sel).length; } catch (e) { return 'throws:' + e.name; } };

  // createDocument: an XML document with no parse step at all.
  sec(() => {
    const d = document.implementation.createDocument(null, 'Root');
    const kid = d.createElement('Kid');
    d.documentElement.appendChild(kid);
    const p = P(d);
    rec('createDoc/type', { Root: p('Root'), root: p('root'), Kid: p('Kid'), kid: p('kid'), KID: p('KID') });
    rec('createDoc/ct', d.contentType);
  });

  // new Document(): also an XML document per spec.
  sec(() => {
    const d = new Document();
    const el = d.createElement('Thing');
    d.appendChild(el);
    rec('newDoc/type', { Thing: P(d)('Thing'), thing: P(d)('thing') });
    rec('newDoc/ct', d.contentType);
  });

  // createHTMLDocument: the control that must stay case-insensitive.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    d.body.innerHTML = '<div></div><svg><clipPath></clipPath></svg>';
    const p = P(d);
    rec('createHTML/type', { div: p('div'), DIV: p('DIV'), clipPath: p('clipPath'), clippath: p('clippath'), CLIPPATH: p('CLIPPATH') });
    rec('createHTML/ct', d.contentType);
  });

  // XHTML with an upper-cased spelling of a known HTML tag, both directions.
  sec(() => {
    const d = new DOMParser().parseFromString(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><P>a</P><span>b</span></body></html>',
      'application/xhtml+xml');
    const p = P(d);
    rec('xhtml/P-elem', { P: p('P'), p: p('p'), span: p('span'), SPAN: p('SPAN') });
    rec('xhtml/P-tagName', d.querySelectorAll('*').length + ':' + Array.prototype.map.call(d.querySelectorAll('*'), (e) => e.localName).join(','));
  });

  return out.map(([a, b]) => a.padEnd(18) + ' -> ' + b).join('\n');
})()
