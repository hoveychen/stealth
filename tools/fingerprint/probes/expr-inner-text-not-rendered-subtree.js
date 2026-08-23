(() => {
  const out = {};
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const mk = (html, style) => {
    const d = document.createElement('div');
    if (style) d.setAttribute('style', style);
    d.innerHTML = html;
    document.body.appendChild(d);
    return [d.innerText, d.textContent];
  };
  out.noneWithBlocks = mk('<p>one</p><p>two</p>', 'display:none');
  out.shownWithBlocks = mk('<p>one</p><p>two</p>', null);
  out.noneWithBr = mk('a<br>b', 'display:none');
  out.hiddenParentChildRead = (() => {
    const p = document.createElement('div');
    p.setAttribute('style', 'display:none');
    const c = document.createElement('div');
    c.innerHTML = '<p>x</p><p>y</p>';
    p.appendChild(c);
    document.body.appendChild(p);
    return [c.innerText, c.textContent];
  })();
  out.styleWithComment = (() => {
    const s = document.createElement('style');
    s.innerHTML = 'a{b:c}';
    document.body.appendChild(s);
    return [s.innerText, s.textContent];
  })();
  return JSON.stringify(out);
})()
