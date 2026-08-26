// Whether the new position calls disagree with Chrome for a reason of their
// own, or share whatever the already-shipped `getSubStringLength` and
// `getExtentOfChar` answer. Same element, every advance reading side by side,
// plus the font the two arms actually resolved it with.
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const host = document.createElement('div');
  host.innerHTML =
    '<svg id="root" width="200" height="100" xmlns="' + NS + '">' +
    '<text id="text" x="5" y="20" font-size="16">Hello</text>' +
    '<text id="serif" x="5" y="60" font-size="16" font-family="serif">Hello</text>' +
    '</svg>';
  document.body.appendChild(host);
  const out = {};
  for (const id of ['text', 'serif']) {
    const t = host.querySelector('#' + id);
    const style = getComputedStyle(t);
    out[id + ' font-family'] = style.fontFamily;
    out[id + ' font-size'] = style.fontSize;
    out[id + ' getComputedTextLength'] = t.getComputedTextLength();
    out[id + ' getSubStringLength(0,1)'] = t.getSubStringLength(0, 1);
    out[id + ' getSubStringLength(0,5)'] = t.getSubStringLength(0, 5);
    out[id + ' getExtentOfChar(0).width'] = t.getExtentOfChar(0).width;
    out[id + ' getExtentOfChar(0).x'] = t.getExtentOfChar(0).x;
    out[id + ' getStartPositionOfChar(1).x'] = t.getStartPositionOfChar(1).x;
    out[id + ' getEndPositionOfChar(0).x'] = t.getEndPositionOfChar(0).x;
  }
  host.remove();
  return JSON.stringify(out);
})()
