(() => {
  const out = [];
  const rec = (label, value) => out.push([label, JSON.stringify(value)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };

  const mk = (src, type) => new DOMParser().parseFromString(src, type);
  const P = (doc) => (sel) => { try { return doc.querySelectorAll(sel).length; } catch (e) { return 'throws:' + e.name; } };
  const G = (doc) => (tag) => { try { return doc.getElementsByTagName(tag).length; } catch (e) { return 'throws:' + e.name; } };

  // 1) text/xml -- type selectors, gEBTN, contentType
  sec(() => {
    const xml = mk('<root xmlns:s="http://www.w3.org/2000/svg"><Thing/><thing/><s:clipPath/></root>', 'text/xml');
    const p = P(xml), g = G(xml);
    rec('xml/type', { Thing: p('Thing'), thing: p('thing'), THING: p('THING') });
    rec('xml/type-svg', { clipPath: p('clipPath'), clippath: p('clippath'), CLIPPATH: p('CLIPPATH') });
    rec('xml/gebtn', { Thing: g('Thing'), thing: g('thing'), THING: g('THING'), clipPath: g('clipPath'), clippath: g('clippath') });
    rec('xml/contentType', xml.contentType);
    rec('xml/tagNames', Array.prototype.map.call(xml.documentElement.children, (e) => e.localName + '|' + e.tagName));
  });

  // 2) text/xml -- attribute name case
  sec(() => {
    const xml = mk('<root><a Foo="1"/><b foo="2"/></root>', 'text/xml');
    const p = P(xml);
    rec('xml/attr-sel', { Foo: p('[Foo]'), foo: p('[foo]'), FOO: p('[FOO]') });
    const a = xml.documentElement.firstElementChild;
    rec('xml/attr-api', {
      getFoo: a.getAttribute('Foo'), getfoo: a.getAttribute('foo'),
      names: Array.prototype.map.call(a.attributes, (x) => x.name),
    });
  });

  // 3) HTML document -- attribute name case on HTML vs SVG element
  sec(() => {
    let html = null;
    try { html = document.implementation.createHTMLDocument('t'); } catch (e) { html = null; }
    if (!html) { try { html = mk('<html><body></body></html>', 'text/html'); } catch (e) { html = null; } }
    if (!html) { rec('html/attr', 'no-html-doc'); return; }
    html.body.innerHTML = '<div Foo="1"></div><svg><g Bar="2"></g></svg>';
    const p = P(html);
    rec('html/attr-div', { Foo: p('[Foo]'), foo: p('[foo]'), FOO: p('[FOO]') });
    rec('html/attr-svg-g', { Bar: p('[Bar]'), bar: p('[bar]'), BAR: p('[BAR]') });
    const g2 = html.querySelector('svg > *');
    rec('html/svg-attr-names', g2 ? Array.prototype.map.call(g2.attributes, (x) => x.name) : null);
    rec('html/contentType', html.contentType);
  });

  // 4) application/xhtml+xml -- type selectors + attributes
  sec(() => {
    const x = mk('<html xmlns="http://www.w3.org/1999/xhtml"><body><p Foo="1">x</p><DIV/></body></html>', 'application/xhtml+xml');
    const p = P(x), g = G(x);
    rec('xhtml/type', { p: p('p'), P: p('P'), body: p('body'), BODY: p('BODY'), DIV: p('DIV'), div: p('div') });
    rec('xhtml/attr-sel', { Foo: p('[Foo]'), foo: p('[foo]') });
    rec('xhtml/gebtn', { p: g('p'), P: g('P') });
    rec('xhtml/contentType', x.contentType);
  });

  // 5) image/svg+xml standalone document
  sec(() => {
    const s = mk('<svg xmlns="http://www.w3.org/2000/svg"><clipPath/><g/></svg>', 'image/svg+xml');
    const p = P(s), g = G(s);
    rec('svgdoc/type', { clipPath: p('clipPath'), clippath: p('clippath'), svg: p('svg'), SVG: p('SVG') });
    rec('svgdoc/gebtn', { clipPath: g('clipPath'), clippath: g('clippath') });
    rec('svgdoc/contentType', s.contentType);
  });

  // 6) the live document for reference
  sec(() => { rec('main/contentType', document.contentType); });

  return out.map(([a, b]) => a.padEnd(20) + ' -> ' + b).join('\n');
})()
