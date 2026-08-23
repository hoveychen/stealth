// Which of the indexed collections expose their indices as *own* properties.
// A page that walks `Object.getOwnPropertyNames(list)` -- or just
// `JSON.stringify(list)` -- reads the difference straight off, and the Turnstile
// widget stringifies `classList`.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-indexed-own-names.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-indexed-own-names.js
(() => {
  const out = {};
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const body = document.body;

  const read = (name, value) => {
    try {
      out[name] = {
        own: Object.getOwnPropertyNames(value).join(' '),
        json: JSON.stringify(value),
        length: value.length,
        keys: Object.keys(value).join(' '),
        spread: (() => { try { return Array.from(value).length; } catch (e) { return 'THREW'; } })(),
      };
    } catch (e) { out[name] = 'THREW ' + e.name; }
  };

  const div = document.createElement('div');
  div.className = 'one two';
  div.setAttribute('id', 'x');
  body.appendChild(div);
  const p1 = document.createElement('p');
  const p2 = document.createElement('p');
  body.appendChild(p1); body.appendChild(p2);

  read('classList', div.classList);
  read('attributes', div.attributes);
  read('childNodes', body.childNodes);
  read('querySelectorAll', document.querySelectorAll('p'));
  read('getElementsByTagName', document.getElementsByTagName('p'));
  read('children', body.children);
  read('styleSheets', document.styleSheets);
  read('getClientRects', div.getClientRects());
  read('relList', (() => { const a = document.createElement('link'); a.rel = 'a b'; return a.relList; })());
  read('formElements', (() => {
    const f = document.createElement('form');
    f.innerHTML = '<input name=a><input name=b>';
    body.appendChild(f);
    return f.elements;
  })());
  read('inlineStyle', (() => { const d = document.createElement('div'); d.style.color = 'red'; return d.style; })());
  read('selectOptions', (() => {
    const s = document.createElement('select');
    s.innerHTML = '<option>a</option><option>b</option>';
    body.appendChild(s);
    return s.options;
  })());
  read('mediaList', (() => {
    const s = document.createElement('style');
    s.textContent = '@media screen, print { .a { color: red } }';
    body.appendChild(s);
    return s.sheet.cssRules[0].media;
  })());
  read('cssRules', (() => {
    const s = document.createElement('style');
    s.textContent = '.a{color:red}.b{color:blue}';
    body.appendChild(s);
    return s.sheet.cssRules;
  })());
  return JSON.stringify(out);
})()
