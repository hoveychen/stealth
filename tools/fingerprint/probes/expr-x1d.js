(() => {
  const out = [];
  const rec = (l, v) => out.push([l, JSON.stringify(v)]);
  const P = (d) => (s) => { try { return d.querySelectorAll(s).length; } catch (e) { return 'throws:' + e.name; } };
  const mk = (src, t) => new DOMParser().parseFromString(src, t);

  const b = mk('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>a</p><DIV/><P>b</P></body></html>', 'application/xhtml+xml');
  const pb = P(b);
  rec('B', { p: pb('p'), P: pb('P'), body: pb('body'), BODY: pb('BODY'), DIV: pb('DIV'), div: pb('div'), star: pb('*') });

  const c = mk('<svg xmlns="http://www.w3.org/2000/svg"><clipPath/><g/></svg>', 'image/svg+xml');
  const pc = P(c);
  rec('C', { clipPath: pc('clipPath'), clippath: pc('clippath'), svg: pc('svg'), SVG: pc('SVG'), g: pc('g'), G: pc('G') });
  return out.map(([a, v]) => a.padEnd(4) + ' -> ' + v).join('\n');
})()
