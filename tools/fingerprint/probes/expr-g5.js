(() => {
  const P = new DOMParser();
  const attrs = (el) => Array.from(el.attributes).map((a) => ({
    name: a.name, value: a.value, ns: a.namespaceURI, prefix: a.prefix, local: a.localName,
  }));
  const el = (e) => e && ({
    tagName: e.tagName, ns: e.namespaceURI, prefix: e.prefix, local: e.localName, attrs: attrs(e),
  });
  const out = {};

  {
    const d = P.parseFromString('<root><kid/></root>', 'text/xml');
    out.bare = { root: el(d.documentElement), kid: el(d.documentElement.firstElementChild) };
  }
  {
    const d = P.parseFromString('<root xmlns="urn:x"><kid/></root>', 'text/xml');
    out.defaultNs = {
      root: el(d.documentElement),
      kid: el(d.documentElement.firstElementChild),
      getAttr: d.documentElement.getAttribute('xmlns'),
      hasAttr: d.documentElement.hasAttribute('xmlns'),
      getAttrNS: d.documentElement.getAttributeNS('http://www.w3.org/2000/xmlns/', 'xmlns'),
      lookupDefault: d.documentElement.lookupNamespaceURI(null),
      serialized: new XMLSerializer().serializeToString(d),
    };
  }
  {
    const d = P.parseFromString('<root xmlns="urn:x"><kid xmlns="urn:y"><g/></kid></root>', 'text/xml');
    const kid = d.documentElement.firstElementChild;
    out.redeclared = { root: el(d.documentElement), kid: el(kid), g: el(kid.firstElementChild) };
  }
  {
    const d = P.parseFromString('<root xmlns="urn:x"><kid xmlns=""/></root>', 'text/xml');
    out.undeclaredBack = { root: el(d.documentElement), kid: el(d.documentElement.firstElementChild) };
  }
  {
    const d = P.parseFromString(
      '<root xmlns:s="http://www.w3.org/2000/svg"><s:g/><plain/></root>', 'text/xml');
    out.prefixed = {
      root: el(d.documentElement),
      g: el(d.documentElement.children[0]),
      plain: el(d.documentElement.children[1]),
      lookupS: d.documentElement.lookupNamespaceURI('s'),
    };
  }
  {
    const d = P.parseFromString(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x</p></body></html>',
      'application/xhtml+xml');
    out.xhtml = { root: el(d.documentElement), p: el(d.querySelector('p')) };
  }
  {
    const d = P.parseFromString(
      '<svg xmlns="http://www.w3.org/2000/svg"><clipPath/></svg>', 'image/svg+xml');
    out.svg = { root: el(d.documentElement), clip: el(d.documentElement.firstElementChild) };
  }
  {
    // Where the collections comparison lands once the namespace is right (G2's
    // input, measured here so the reading exists before that work starts).
    const d = P.parseFromString('<root xmlns="urn:x"><Thing/></root>', 'text/xml');
    const b = P.parseFromString('<root><Thing/></root>', 'text/xml');
    out.collections = {
      declared_null: d.getElementsByTagNameNS(null, 'Thing').length,
      declared_urn: d.getElementsByTagNameNS('urn:x', 'Thing').length,
      declared_star: d.getElementsByTagNameNS('*', 'Thing').length,
      bare_null: b.getElementsByTagNameNS(null, 'Thing').length,
      bare_star: b.getElementsByTagNameNS('*', 'Thing').length,
    };
  }
  {
    // createDocument's own answers, for the no-parser column.
    const d = document.implementation.createDocument('urn:x', 'Root');
    const d2 = document.implementation.createDocument(null, 'Root');
    out.createDocument = { withNs: el(d.documentElement), withoutNs: el(d2.documentElement) };
  }
  return out;
})()
