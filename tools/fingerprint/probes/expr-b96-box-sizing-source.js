(() => {
  const out = {};
  const host = document.createElement('div');
  host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
  document.body.appendChild(host);
  const probe = document.createElement('div');
  probe.id = 'bs-probe';
  probe.setAttribute('style', 'width:100px;padding:10px;border:5px solid');
  host.appendChild(probe);

  const read = (label) => {
    const cs = getComputedStyle(probe);
    out[label] = `boxSizing=${cs.boxSizing} width=${cs.width} client=${probe.clientWidth} offset=${probe.offsetWidth}`;
  };
  read('noRule');

  const cases = [
    ['universalOnly', '*{box-sizing:border-box}'],
    ['universalPseudos', '*,::before,::after{box-sizing:border-box}'],
    ['universalPseudosSpaced', '*, ::before, ::after { box-sizing: border-box }'],
    ['byId', '#bs-probe{box-sizing:border-box}'],
    ['byTag', 'div{box-sizing:border-box}'],
    ['listWithUnknownPseudo', 'div,::selection{box-sizing:border-box}'],
    ['inherit', '*{box-sizing:inherit}'],
  ];
  for (const [label, css] of cases) {
    const sheet = document.createElement('style');
    sheet.textContent = css;
    document.head.appendChild(sheet);
    read(label);
    sheet.remove();
  }
  // ...and the same declaration on the element itself, as the control.
  probe.style.boxSizing = 'border-box';
  read('inlineOnElement');

  host.remove();
  return out;
})()
