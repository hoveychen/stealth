(() => {
  const p = new DOMParser();
  const SVG = 'http://www.w3.org/2000/svg';
  const attrs = (el) => Array.from(el.attributes).map((a) => [a.name, a.value]);
  const out = {};
  out.none = attrs(p.parseFromString('<root><kid/></root>', 'text/xml').documentElement);
  const d1 = p.parseFromString('<root xmlns="urn:x"><kid/></root>', 'text/xml');
  out.declared = attrs(d1.documentElement);
  out.declared_child = attrs(d1.documentElement.firstElementChild);
  out.empty_decl = attrs(p.parseFromString('<root xmlns="urn:x"><kid xmlns=""/></root>', 'text/xml').documentElement.firstElementChild);
  const d2 = p.parseFromString('<root xmlns:s="' + SVG + '"><s:g/><plain/></root>', 'text/xml');
  out.prefix_decl = attrs(d2.documentElement);
  out.prefix_lookup = d2.documentElement.lookupNamespaceURI('s');
  out.order_mid = attrs(p.parseFromString('<root a="1" xmlns="urn:x" b="2"/>', 'text/xml').documentElement);
  out.order_last = attrs(p.parseFromString('<root a="1" b="2" xmlns="urn:x"/>', 'text/xml').documentElement);
  out.created = attrs(document.implementation.createDocument('urn:x', 'Root').documentElement);
  // namespaceURI half, already committed
  out.ns_declared = d1.documentElement.namespaceURI;
  out.ns_undeclared = p.parseFromString('<root/>', 'text/xml').documentElement.namespaceURI;
  return out;
})()
