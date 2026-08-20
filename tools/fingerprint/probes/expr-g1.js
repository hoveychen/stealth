(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };

  const SVG = 'http://www.w3.org/2000/svg';
  const XHTML = 'http://www.w3.org/1999/xhtml';
  const parse = (s, t) => new DOMParser().parseFromString(s, t);

  const XHTML_DOC = '<html xmlns="' + XHTML + '"><body><p Foo="1">a</p><DIV/><P>b</P></body></html>';
  const XML_DOC = '<root xmlns:s="' + SVG + '"><s:clipPath/><Thing/><thing/></root>';

  // 1) contentType: does it echo the mime the document was parsed as?
  sec(() => {
    rec('contentType', {
      xml: parse('<r/>', 'text/xml').contentType,
      xhtml: parse(XHTML_DOC, 'application/xhtml+xml').contentType,
      svg: parse('<svg xmlns="' + SVG + '"/>', 'image/svg+xml').contentType,
      appxml: parse('<r/>', 'application/xml').contentType,
      html: parse('<p>x</p>', 'text/html').contentType,
      created_html: document.implementation.createHTMLDocument('t').contentType,
      created_xml: document.implementation.createDocument(null, 'Root').contentType,
      own: document.contentType,
    });
  });

  // 2) tagName / localName / prefix in an XML document. An XHTML <p> is
  //    HTML-namespaced but the document is XML, so nothing is uppercased.
  sec(() => {
    const d = parse(XHTML_DOC, 'application/xhtml+xml');
    const names = (el) => el && [el.tagName, el.localName, String(el.prefix), el.nodeName].join('|');
    rec('xhtml/tagName', {
      p: names(d.getElementsByTagNameNS(XHTML, 'p')[0]),
      div: names([...d.querySelectorAll('*')].find((e) => e.localName === 'DIV' || e.localName === 'div')),
      all: [...d.querySelectorAll('*')].map((e) => e.tagName).join(','),
    });
  });

  // 3) A prefixed foreign element: is the prefix kept in tagName?
  sec(() => {
    const d = parse(XML_DOC, 'text/xml');
    const el = d.documentElement.firstElementChild;
    rec('xml/prefixed', {
      tagName: el.tagName, localName: el.localName, prefix: String(el.prefix),
      nodeName: el.nodeName, ns: String(el.namespaceURI),
      all: [...d.querySelectorAll('*')].map((e) => e.tagName).join(','),
    });
  });

  // 4) namespaceURI with no xmlns at all, and the xmlns attribute itself.
  sec(() => {
    const bare = parse('<root><kid/></root>', 'text/xml');
    const withns = parse('<root xmlns="urn:x"><kid/></root>', 'text/xml');
    const attrs = (el) => Array.prototype.map.call(el.attributes, (a) => a.name + '=' + a.value);
    rec('namespaceURI', {
      bare_root: String(bare.documentElement.namespaceURI),
      bare_kid: String(bare.documentElement.firstElementChild.namespaceURI),
      with_root: String(withns.documentElement.namespaceURI),
      with_kid: String(withns.documentElement.firstElementChild.namespaceURI),
      bare_attrs: attrs(bare.documentElement),
      with_attrs: attrs(withns.documentElement),
      xhtml_attrs: attrs(parse(XHTML_DOC, 'application/xhtml+xml').documentElement),
      xml_attrs: attrs(parse(XML_DOC, 'text/xml').documentElement),
    });
  });

  // 5) getElementsByTagName: the collections comparison, which is separate from
  //    the selector one. It lowercases its argument only for HTML elements.
  sec(() => {
    const g = (d) => (n) => d.getElementsByTagName(n).length;
    const xhtml = g(parse(XHTML_DOC, 'application/xhtml+xml'));
    const xml = g(parse(XML_DOC, 'text/xml'));
    const html = document.implementation.createHTMLDocument('t');
    html.body.innerHTML = '<div></div><svg><clipPath></clipPath></svg>';
    const h = g(html);
    // The XHTML doc holds both <p>a</p> and <P>b</P>, so a bare count cannot
    // say which one a spelling found: read the text back too.
    const xd = parse(XHTML_DOC, 'application/xhtml+xml');
    const text = (n) => [...xd.getElementsByTagName(n)].map((e) => e.textContent).join(',');
    // And the README's row, which used a document holding only <p>.
    const only_p = g(parse('<html xmlns="' + XHTML + '"><body><p>a</p></body></html>',
      'application/xhtml+xml'));
    rec('gEBTN', {
      xhtml_p_text: text('p'), xhtml_P_text: text('P'),
      only_p_lower: only_p('p'), only_p_upper: only_p('P'),
      xhtml_p: xhtml('p'), xhtml_P: xhtml('P'), xhtml_div: xhtml('div'), xhtml_DIV: xhtml('DIV'),
      xml_Thing: xml('Thing'), xml_thing: xml('thing'), xml_THING: xml('THING'),
      xml_clip: xml('s:clipPath'), xml_clip_local: xml('clipPath'),
      html_div: h('div'), html_DIV: h('DIV'),
      html_clip: h('clipPath'), html_clip_low: h('clippath'), html_clip_up: h('CLIPPATH'),
      html_star: h('*'),
    });
  });

  // 6) The namespaced form, for contrast: it is defined on local names only.
  sec(() => {
    const gns = (d) => (ns, n) => d.getElementsByTagNameNS(ns, n).length;
    const xhtml = gns(parse(XHTML_DOC, 'application/xhtml+xml'));
    const xml = gns(parse(XML_DOC, 'text/xml'));
    rec('gEBTNNS', {
      xhtml_p: xhtml(XHTML, 'p'), xhtml_P: xhtml(XHTML, 'P'),
      xhtml_star: xhtml('*', '*'), xhtml_null_p: xhtml(null, 'p'),
      xml_clip: xml(SVG, 'clipPath'), xml_clip_low: xml(SVG, 'clippath'),
      xml_Thing: xml(null, 'Thing'), xml_thing: xml(null, 'thing'),
    });
  });

  return out.map(([a, v]) => a.padEnd(16) + ' -> ' + v).join('\n');
})()
