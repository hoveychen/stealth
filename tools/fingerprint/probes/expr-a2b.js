(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };
  const P = (d) => (s) => { try { return d.querySelectorAll(s).length; } catch (e) { return 'throws:' + e.name; } };
  const stored = (el) => Array.prototype.map.call(el.attributes, (a) => a.name + '=' + a.value);

  const SVG = 'http://www.w3.org/2000/svg';

  // a2 showed that when a foreign element carries both spellings, a folded
  // selector reads the *capital* one. Is that document order, or a preference
  // for the non-exact one? Set them the other way round.
  const both = (d, first, second) => {
    const g = d.createElementNS(SVG, 'g');
    g.setAttribute(first, first === 'Bar' ? 'cap' : 'low');
    g.setAttribute(second, second === 'Bar' ? 'cap' : 'low');
    (d.body || d.documentElement).appendChild(g);
    return g;
  };

  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const g = both(d, 'bar', 'Bar');
    const p = P(d);
    rec('html/low-first', { stored: stored(g), cap: p('[bar="cap"]'), low: p('[bar="low"]'), Cap: p('[Bar="cap"]'), Low: p('[Bar="low"]') });
  });

  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const g = both(d, 'Bar', 'bar');
    const p = P(d);
    rec('html/cap-first', { stored: stored(g), cap: p('[bar="cap"]'), low: p('[bar="low"]'), Cap: p('[Bar="cap"]'), Low: p('[Bar="low"]') });
  });

  // The same pair in an XML document, where each spelling should pick out only
  // itself no matter which came first.
  sec(() => {
    const d = new DOMParser().parseFromString(
      '<root xmlns:s="http://www.w3.org/2000/svg"><s:g Bar="cap" bar="low"/></root>', 'text/xml');
    const p = P(d);
    rec('xml/cap-first', { stored: stored(d.documentElement.firstChild), cap: p('[Bar="cap"]'), low: p('[bar="low"]'), cross1: p('[Bar="low"]'), cross2: p('[bar="cap"]') });
  });

  sec(() => {
    const d = new DOMParser().parseFromString(
      '<root xmlns:s="http://www.w3.org/2000/svg"><s:g bar="low" Bar="cap"/></root>', 'text/xml');
    const p = P(d);
    rec('xml/low-first', { stored: stored(d.documentElement.firstChild), cap: p('[Bar="cap"]'), low: p('[bar="low"]'), cross1: p('[Bar="low"]'), cross2: p('[bar="cap"]') });
  });

  return out.map(([a, v]) => a.padEnd(20) + ' -> ' + v).join('\n');
})()
