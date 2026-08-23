// Every tag this engine classes "never rendered" for innerText, asked of Chrome
// with text inside it. The spec's first step returns the descendant text
// content for an element that is not being rendered, so "" is only right where
// the element genuinely has no text.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-inner-text-skip-tags.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-inner-text-skip-tags.js
(() => {
  const out = {};
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const TAGS = ['style', 'script', 'template', 'base', 'link', 'meta', 'title',
                'source', 'track', 'param', 'area', 'datalist', 'noscript',
                'dialog', 'rp', 'optgroup', 'option', 'select', 'textarea'];
  for (const t of TAGS) {
    const el = document.createElement(t);
    el.textContent = 'T' + t;
    document.body.appendChild(el);
    out[t] = [el.innerText, el.textContent];
  }
  // head and its children are the other never-rendered subtree.
  const s = document.createElement('style');
  s.textContent = 'Thead-style';
  (document.head || document.documentElement).appendChild(s);
  out['head>style'] = [s.innerText, s.textContent];
  return JSON.stringify(out);
})()
