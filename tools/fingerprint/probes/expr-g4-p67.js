(() => {
  const p = new DOMParser();
  const XHTML = 'http://www.w3.org/1999/xhtml';
  const SVG = 'http://www.w3.org/2000/svg';
  const info = (el) => el === null ? null : [el.tagName, el.nodeName, el.localName, el.prefix, el.namespaceURI];
  const out = {};

  // Plain XML: case is preserved, both spellings.
  const x = p.parseFromString('<Root><kid/><KID/></Root>', 'text/xml');
  out.xml_root = info(x.documentElement);
  out.xml_lower_kid = info(x.documentElement.children[0]);
  out.xml_upper_kid = info(x.documentElement.children[1]);

  // XHTML: an HTML-namespace element parsed as XML.
  const h = p.parseFromString(
    '<html xmlns="' + XHTML + '"><body><p>x</p><DIV/></body></html>', 'application/xhtml+xml');
  out.xhtml_html = info(h.documentElement);
  out.xhtml_body = info(h.getElementsByTagNameNS(XHTML, 'body')[0]);
  out.xhtml_p = info(h.getElementsByTagNameNS(XHTML, 'p')[0]);
  out.xhtml_DIV = info(h.getElementsByTagNameNS(XHTML, 'DIV')[0]);

  // Prefixed element in an XML document.
  const s = p.parseFromString(
    '<root xmlns:s="' + SVG + '"><s:clipPath/><s:g/></root>', 'text/xml');
  out.xml_prefixed_clipPath = info(s.documentElement.children[0]);
  out.xml_prefixed_g = info(s.documentElement.children[1]);

  // Default-namespace SVG document.
  const svgdoc = p.parseFromString('<svg xmlns="' + SVG + '"><clipPath/><g/></svg>', 'image/svg+xml');
  out.svgdoc_root = info(svgdoc.documentElement);
  out.svgdoc_clipPath = info(svgdoc.documentElement.children[0]);

  // HTML document, for contrast.
  const hd = p.parseFromString('<p>x</p><svg><clipPath/></svg>', 'text/html');
  out.html_p = info(hd.querySelector('p'));
  out.html_clipPath = info(hd.querySelector('clipPath'));

  // Serialization of the prefixed element.
  out.xml_prefixed_outer = s.documentElement.children[0].outerHTML;
  out.xhtml_p_outer = h.getElementsByTagNameNS(XHTML, 'p')[0].outerHTML;
  return out;
})()
