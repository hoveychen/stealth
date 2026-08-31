(() => {
  const b = document.body, d = document.documentElement;
  const before = b.getAttribute('style');
  const read = (label) => {
    const cs = getComputedStyle(b);
    return `${label}: margin=${cs.marginLeft} client=${b.clientWidth} html=${d.clientWidth} delta=${d.clientWidth - b.clientWidth}`;
  };
  const out = {};
  out.asFound = read('asFound');
  b.style.margin = '0px';
  out.inline0 = read('inline0');
  b.style.margin = '3px';
  out.inline3 = read('inline3');
  b.style.margin = '8px';
  out.inline8 = read('inline8');
  b.style.margin = '0 20px';
  out.inline0x20 = read('inline0x20');
  if (before === null) b.removeAttribute('style'); else b.setAttribute('style', before);
  return out;
})()
