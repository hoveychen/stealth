(() => {
  const p = new DOMParser();
  const XHTML = 'http://www.w3.org/1999/xhtml';
  const SVG = 'http://www.w3.org/2000/svg';
  const out = {};
  const names = (list) => Array.from(list).map((e) => e.tagName);

  {
    const d = p.parseFromString('<Root><kid/><KID/></Root>', 'text/xml');
    const g = (n) => names(d.getElementsByTagName(n));
    out.xml_Root = g('Root'); out.xml_root_lower = g('root');
    out.xml_kid = g('kid'); out.xml_KID = g('KID');
    out.xml_star = g('*');
    out.xml_ns_kid = names(d.getElementsByTagNameNS('*', 'kid'));
    out.xml_ns_KID = names(d.getElementsByTagNameNS('*', 'KID'));
    out.xml_ns_null_kid = names(d.getElementsByTagNameNS(null, 'kid'));
  }

  {
    const d = p.parseFromString(
      '<html xmlns="' + XHTML + '"><body><p/><DIV/></body></html>', 'application/xhtml+xml');
    const g = (n) => names(d.getElementsByTagName(n));
    out.xhtml_p = g('p'); out.xhtml_P = g('P');
    out.xhtml_DIV = g('DIV'); out.xhtml_div = g('div');
    out.xhtml_body = g('body'); out.xhtml_BODY = g('BODY');
    out.xhtml_ns_p = names(d.getElementsByTagNameNS(XHTML, 'p'));
    out.xhtml_ns_P = names(d.getElementsByTagNameNS(XHTML, 'P'));
    out.xhtml_ns_DIV = names(d.getElementsByTagNameNS(XHTML, 'DIV'));
  }

  {
    const d = p.parseFromString(
      '<root xmlns:s="' + SVG + '"><s:clipPath/><s:g/></root>', 'text/xml');
    const g = (n) => names(d.getElementsByTagName(n));
    out.pfx_qualified = g('s:clipPath'); out.pfx_local = g('clipPath');
    out.pfx_g_qualified = g('s:g'); out.pfx_g_local = g('g');
    out.pfx_lower = g('s:clippath');
    out.pfx_ns_local = names(d.getElementsByTagNameNS(SVG, 'clipPath'));
    out.pfx_ns_qualified = names(d.getElementsByTagNameNS(SVG, 's:clipPath'));
    out.pfx_ns_star_local = names(d.getElementsByTagNameNS('*', 'clipPath'));
  }

  {
    // HTML document: already aligned; guard against regressing it.
    const d = p.parseFromString('<p>x</p><svg><clipPath/></svg>', 'text/html');
    const g = (n) => names(d.getElementsByTagName(n));
    out.html_p = g('p'); out.html_P = g('P');
    out.html_clipPath = g('clipPath'); out.html_clippath = g('clippath');
    out.html_ns_clipPath = names(d.getElementsByTagNameNS(SVG, 'clipPath'));
    out.html_ns_clippath = names(d.getElementsByTagNameNS(SVG, 'clippath'));
  }
  return out;
})()
