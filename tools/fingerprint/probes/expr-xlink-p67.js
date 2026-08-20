(() => {
  const out = {};
  const host = document.createElement('div');
  host.innerHTML = '<svg><use id=u1 xlink:href="#icon"></use><use id=u2 href="#modern" xlink:href="#legacy"></use></svg>';
  // Left detached on purpose: about:blank has no <body> in this engine (and no
  // documentElement either), and nothing measured here needs to be connected.
  const u1 = host.querySelector('#u1');
  const u2 = host.querySelector('#u2');
  const attrs = (el) => Array.from(el.attributes).map((a) => [a.name, a.localName, a.namespaceURI, a.value]);

  out.u1_attrs = attrs(u1);
  out.u1_href_baseVal = u1.href.baseVal;
  out.u1_getAttribute_href = u1.getAttribute('href');
  out.u1_getAttribute_xlinkhref = u1.getAttribute('xlink:href');
  out.u2_href_baseVal = u2.href.baseVal;
  out.u2_attrs = attrs(u2);

  // Where does a write land when only xlink:href exists?
  u1.href.baseVal = '#other';
  out.u1_after_write_attrs = attrs(u1);
  out.u1_after_write_baseVal = u1.href.baseVal;

  // setAttribute with a literal colon name: no namespace.
  const u4 = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  u4.setAttribute('xlink:href', '#literal');
  out.u4_attrs = attrs(u4);
  out.u4_href_baseVal = u4.href.baseVal;
  u4.href.baseVal = '#written';
  out.u4_after_write_attrs = attrs(u4);

  // setAttributeNS in the xlink namespace.
  const u3 = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  u3.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', '#runtime');
  out.u3_attrs = attrs(u3);
  out.u3_href_baseVal = u3.href.baseVal;
  return out;
})()
