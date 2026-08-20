(() => {
  const out = [];
  const P = (d) => (s) => { try { return d.querySelectorAll(s).length; } catch (e) { return 'throws:' + e.name; } };
  const d = new DOMParser().parseFromString(
    '<root xmlns:s="http://www.w3.org/2000/svg"><s:g Bar="one two"/></root>', 'text/xml');
  const p = P(d);
  out.push(['xml/exact-name+i', JSON.stringify({
    i: p('[Bar="ONE TWO" i]'), s: p('[Bar="ONE TWO"]'), plain: p('[Bar="one two"]'),
  })]);
  return out.map(([a, v]) => a.padEnd(20) + ' -> ' + v).join('\n');
})()
