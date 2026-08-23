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
  read('keyframesRule', (() => {
    const s = document.createElement('style');
    s.textContent = '@keyframes k { from { opacity: 0 } to { opacity: 1 } }';
    body.appendChild(s);
    return s.sheet.cssRules[0];
  })());
  read('radioNodeList', (() => {
    const f = document.createElement('form');
    f.innerHTML = '<input type=radio name=r value=a><input type=radio name=r value=b>';
    body.appendChild(f);
    return f.elements.r;
  })());
  read('formControls', (() => {
    const f = document.createElement('form');
    f.innerHTML = '<input name=a><select name=b></select>';
    body.appendChild(f);
    return f.elements;
  })());
  read('documentAll', document.all);
  // The first `styleSheets` read above happens before any <style> is in the
  // document, so it is the empty case; this is the same list with entries.
  read('styleSheetsFilled', document.styleSheets);

  // `window`'s own names are thousands long, so only the numeric ones -- the
  // frame indices -- are reported. Chrome makes those own properties too, and
  // the named access (`window.fa`) is a separate mechanism that must survive.
  out.windowFrames = (() => {
    const a = document.createElement('iframe');
    const b = document.createElement('iframe');
    a.name = 'fa';
    b.name = 'fb';
    body.appendChild(a);
    body.appendChild(b);
    return {
      own: Object.getOwnPropertyNames(window).filter((k) => /^\d+$/.test(k)).join(' '),
      keys: Object.keys(window).filter((k) => /^\d+$/.test(k)).join(' '),
      length: window.length,
      zeroIsWindow: typeof window[0] === 'object',
      named: typeof window.fa === 'object',
      inOperator: 0 in window,
      descriptor: (() => {
        const d = Object.getOwnPropertyDescriptor(window, 0);
        return d ? { enumerable: d.enumerable, configurable: d.configurable, writable: d.writable, kind: d.get ? 'accessor' : 'data' } : null;
      })(),
    };
  })();
  return JSON.stringify(out);
})()
