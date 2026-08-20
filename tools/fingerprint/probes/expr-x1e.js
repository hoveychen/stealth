(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const b = new DOMParser().parseFromString('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>a</p><DIV/><P>b</P></body></html>', 'application/xhtml+xml');
  const id = (s) => { try { return Array.prototype.map.call(b.querySelectorAll(s), (e) => e.localName + ':' + e.textContent); } catch (e) { return 'throws'; } };
  rec('p', id('p')); rec('P', id('P')); rec('DIV', id('DIV')); rec('div', id('div'));
  return out.map(([a, v]) => a.padEnd(4) + ' -> ' + v).join('\n');
})()
