(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };
  const P = (d) => (s) => { try { return d.querySelectorAll(s).length; } catch (e) { return 'throws:' + e.name; } };
  const names = (el) => Array.prototype.map.call(el.attributes, (a) => a.name);

  const SVG = 'http://www.w3.org/2000/svg';

  // 1) HTML document, foreign element, attribute set with a capital. setAttribute
  //    only lowercases for HTML-namespaced elements, so the stored name keeps the
  //    capital -- which separates "matches case-insensitively" from "both sides
  //    were lowercase all along".
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const g = d.createElementNS(SVG, 'g');
    g.setAttribute('Bar', '1');
    d.body.appendChild(g);
    const p = P(d);
    rec('html/foreign-cap', { stored: names(g), Bar: p('[Bar]'), bar: p('[bar]'), BAR: p('[BAR]') });
  });

  // 2) HTML document, HTML element, same thing: setAttribute lowercases here.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const div = d.createElement('div');
    div.setAttribute('Foo', '1');
    d.body.appendChild(div);
    const p = P(d);
    rec('html/html-cap', { stored: names(div), Foo: p('[Foo]'), foo: p('[foo]'), FOO: p('[FOO]') });
  });

  // 3) HTML document, the parser's SVG attribute-case adjustment table.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    d.body.innerHTML = '<svg viewBox="0 0 10 10" preserveAspectRatio="none"></svg>';
    const svg = d.querySelector('svg');
    const p = P(d);
    rec('html/viewBox', {
      stored: names(svg),
      viewBox: p('[viewBox]'), viewbox: p('[viewbox]'), VIEWBOX: p('[VIEWBOX]'),
      preserveAspectRatio: p('[preserveAspectRatio]'), preserveaspectratio: p('[preserveaspectratio]'),
    });
  });

  // 4) XML document, HTML-namespaced element with a capitalized attribute.
  sec(() => {
    const d = new DOMParser().parseFromString(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p Foo="1">x</p></body></html>',
      'application/xhtml+xml');
    const p = P(d);
    rec('xhtml/attr', { stored: names(d.querySelector('p')), Foo: p('[Foo]'), foo: p('[foo]'), FOO: p('[FOO]') });
  });

  // 5) XML document, foreign element with a capitalized attribute.
  sec(() => {
    const d = new DOMParser().parseFromString(
      '<root xmlns:s="http://www.w3.org/2000/svg"><s:g Bar="1"/><s:rect bar="2"/></root>', 'text/xml');
    const p = P(d);
    rec('xml/foreign-attr', { Bar: p('[Bar]'), bar: p('[bar]'), BAR: p('[BAR]') });
  });

  // 6) XML document, setAttribute on both namespaces (no parser in the way).
  sec(() => {
    const d = document.implementation.createDocument(null, 'Root');
    const a = d.createElement('a');
    a.setAttribute('Foo', '1');
    d.documentElement.appendChild(a);
    const p = P(d);
    rec('xmldoc/setAttr', { stored: names(a), Foo: p('[Foo]'), foo: p('[foo]') });
  });

  // 7) The value-side `i` flag, for contrast: that one is about the value.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    d.body.innerHTML = '<div data-x="ABC"></div>';
    const p = P(d);
    rec('html/value-i', { exact: p('[data-x="ABC"]'), lower: p('[data-x="abc"]'), lower_i: p('[data-x="abc" i]') });
  });

  return out.map(([a, v]) => a.padEnd(18) + ' -> ' + v).join('\n');
})()
