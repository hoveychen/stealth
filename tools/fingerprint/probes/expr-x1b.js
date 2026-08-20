(() => {
  const out = [];
  const rec = (label, value) => out.push([label, JSON.stringify(value)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };
  const mk = (src, type) => new DOMParser().parseFromString(src, type);

  const dump = (el, depth) => {
    const pad = '  '.repeat(depth);
    let s = pad + el.nodeName + ' [local=' + el.localName + ' ns=' + (el.namespaceURI || 'null') + ' prefix=' + (el.prefix || 'null') + ']';
    if (el.attributes) {
      s += ' attrs={' + Array.prototype.map.call(el.attributes, (a) => a.name + '/' + a.localName + '=' + a.value).join(',') + '}';
    }
    const kids = el.children || [];
    for (let i = 0; i < kids.length; i++) s += '\n' + dump(kids[i], depth + 1);
    return s;
  };

  sec(() => {
    const x = mk('<html xmlns="http://www.w3.org/1999/xhtml"><body><p Foo="1">x</p><DIV/></body></html>', 'application/xhtml+xml');
    rec('xhtml/tree', '\n' + dump(x.documentElement, 0));
    rec('xhtml/all', Array.prototype.map.call(x.querySelectorAll('*'), (e) => e.nodeName));
    rec('xhtml/star-count', x.querySelectorAll('*').length);
  });

  sec(() => {
    const x = mk('<root><a Foo="1"/></root>', 'text/xml');
    rec('xml/tree', '\n' + dump(x.documentElement, 0));
  });

  sec(() => {
    let html = null;
    try { html = document.implementation.createHTMLDocument('t'); } catch (e) {}
    if (!html) { rec('html', 'no-doc'); return; }
    html.body.innerHTML = '<div Foo="1"></div><svg><g Bar="2"></g></svg>';
    rec('html/tree', '\n' + dump(html.body, 0));
  });

  return out.map(([a, b]) => a.padEnd(16) + ' -> ' + b).join('\n');
})()
