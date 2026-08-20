(() => {
  const P = new DOMParser();
  const attrs = (el) => Array.from(el.attributes).map((a) => [a.name, a.value, a.namespaceURI]);
  const out = {};
  const doc = (s) => P.parseFromString(s, 'text/xml').documentElement;

  out.order_middle = attrs(doc('<root a="1" xmlns="urn:x" b="2"/>'));
  out.order_first = attrs(doc('<root xmlns="urn:x" a="1" b="2"/>'));
  out.order_last = attrs(doc('<root a="1" b="2" xmlns="urn:x"/>'));
  out.order_prefixed = attrs(doc('<root a="1" xmlns:s="urn:s" s:b="2"/>'));
  out.both = attrs(doc('<root xmlns="urn:x" xmlns:s="urn:s"/>'));

  // Named-access and the attribute node's own identity.
  const e = doc('<root xmlns:s="urn:s"/>');
  out.namedItem = e.attributes.getNamedItem('xmlns:s')?.value ?? null;
  // Wrapped like probe.js wraps its reads: this engine has no
  // getNamedItemNS at all, and "the method is missing" is a reading, not a
  // reason to lose the other rows.
  try {
    out.namedItemNS = e.attributes.getNamedItemNS('http://www.w3.org/2000/xmlns/', 's')?.value ?? null;
  } catch (err) {
    out.namedItemNS = String(err);
  }
  out.getAttributeNS = e.getAttributeNS('http://www.w3.org/2000/xmlns/', 's');
  out.hasAttribute = e.hasAttribute('xmlns:s');
  out.outerHTML = e.outerHTML;

  // A prefixed attribute keeps its prefix in `name` -- the shape the xmlns:s
  // attribute has to match.
  const p = doc('<root xmlns:s="urn:s" s:b="2"/>');
  const b = p.attributes[1];
  out.prefixedAttr = { name: b.name, ns: b.namespaceURI, prefix: b.prefix, local: b.localName };
  return out;
})()
