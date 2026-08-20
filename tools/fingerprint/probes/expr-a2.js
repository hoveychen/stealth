(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const sec = (fn) => { try { fn(); } catch (e) { rec('ERR', String(e && e.message || e)); } };
  const P = (d) => (s) => { try { return d.querySelectorAll(s).length; } catch (e) { return 'throws:' + e.name; } };

  const SVG = 'http://www.w3.org/2000/svg';

  // A1 settled the *name* rule. A2 needs the one composition it did not cover:
  // when the name is reached by a case fold, do the value matchers still read
  // the value the ordinary way?
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const g = d.createElementNS(SVG, 'g');
    g.setAttribute('Bar', 'one two');
    d.body.appendChild(g);
    const p = P(d);
    rec('html/fold+value', {
      exact: p('[bar="one two"]'), wrong: p('[bar="nope"]'),
      word: p('[bar~="two"]'), starts: p('[bar^="one"]'),
      ends: p('[bar$="two"]'), sub: p('[bar*="e t"]'),
      exact_i: p('[bar="ONE TWO" i]'), exact_s: p('[bar="ONE TWO"]'),
    });
  });

  // The same composition in an XML document, where the name must not fold: the
  // value matcher should never get a chance to run.
  sec(() => {
    const d = new DOMParser().parseFromString(
      '<root xmlns:s="http://www.w3.org/2000/svg"><s:g Bar="one two"/></root>', 'text/xml');
    const p = P(d);
    rec('xml/fold+value', {
      Bar_exact: p('[Bar="one two"]'), bar_exact: p('[bar="one two"]'),
      bar_word: p('[bar~="two"]'), bar_exact_i: p('[bar="ONE TWO" i]'),
    });
  });

  // The parser-kept capital reached by the lowercase spelling a stylesheet
  // would carry, combined with a type selector.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    d.body.innerHTML = '<svg viewBox="0 0 10 10"><rect/></svg>';
    const p = P(d);
    rec('html/svg[viewbox]', {
      compound: p('svg[viewbox]'), compound_camel: p('svg[viewBox]'),
      value: p('[viewbox="0 0 10 10"]'), starts: p('[viewbox^="0 0"]'),
      getAttr: d.querySelector('svg[viewbox]').getAttribute('viewBox'),
    });
  });

  // An element carrying both spellings at once, which only a foreign element
  // can: which one a folded selector reads the value of.
  sec(() => {
    const d = document.implementation.createHTMLDocument('t');
    const g = d.createElementNS(SVG, 'g');
    g.setAttribute('Bar', 'cap');
    g.setAttribute('bar', 'low');
    d.body.appendChild(g);
    const p = P(d);
    rec('html/both-spellings', {
      stored: Array.prototype.map.call(g.attributes, (a) => a.name + '=' + a.value),
      cap: p('[bar="cap"]'), low: p('[bar="low"]'), presence: p('[bar]'),
    });
  });

  return out.map(([a, v]) => a.padEnd(20) + ' -> ' + v).join('\n');
})()
