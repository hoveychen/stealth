(() => {
  const out = {};
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const d = document.createElement('div');
  d.innerHTML = '<p>one</p><p>two</p>';
  out.detachedWithBlocks = [d.innerText, d.textContent, d.isConnected];
  const t = document.createElement('template');
  t.innerHTML = '<p>a</p><p>b</p>';
  document.body.appendChild(t);
  const inner = t.content.querySelector('p');
  out.templateContentChild = [inner.innerText, inner.textContent];
  const h = document.createElement('div');
  h.innerHTML = '<p>h1</p><p>h2</p>';
  (document.head || document.documentElement).appendChild(h);
  out.inHead = [h.innerText, h.textContent];
  return JSON.stringify(out);
})()
