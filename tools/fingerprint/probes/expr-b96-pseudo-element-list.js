(() => {
  const out = {};
  const host = document.createElement('div');
  host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
  document.body.appendChild(host);
  const probe = document.createElement('div');
  probe.id = 'bs2';
  probe.setAttribute('style', 'width:100px;padding:10px;border:5px solid;box-sizing:content-box');
  host.appendChild(probe);

  // The declaration under test cannot be box-sizing here (the inline one above
  // would win); use a property with no inline declaration.
  const read = (label) => { out[label] = getComputedStyle(probe).letterSpacing; };
  const cases = [
    ['plain', '#bs2{letter-spacing:3px}'],
    ['withKnownPseudoElement', '#bs2,::before{letter-spacing:3px}'],
    ['withUnknownPseudoElement', '#bs2,::totally-unknown-thing{letter-spacing:3px}'],
    ['withVendorPseudoElement', '#bs2,::-webkit-scrollbar{letter-spacing:3px}'],
    ['withUnknownPseudoClass', '#bs2,:totally-unknown-class{letter-spacing:3px}'],
    ['withBadSyntax', '#bs2,>>>{letter-spacing:3px}'],
    ['pseudoElementOnTheElement', '#bs2::before{letter-spacing:3px}'],
    ['singleColonBefore', '#bs2,:before{letter-spacing:3px}'],
    ['unknownVendorPseudo', '#bs2,::-webkit-nonsense-xyz{letter-spacing:3px}'],
    ['unknownMozPseudo', '#bs2,::-moz-nonsense-xyz{letter-spacing:3px}'],
    ['firstLine', '#bs2,::first-line{letter-spacing:3px}'],
    ['placeholder', '#bs2,::placeholder{letter-spacing:3px}'],
    ['marker', '#bs2,::marker{letter-spacing:3px}'],
    ['backdrop', '#bs2,::backdrop{letter-spacing:3px}'],
    ['selection', '#bs2,::selection{letter-spacing:3px}'],
    ['fileSelectorButton', '#bs2,::file-selector-button{letter-spacing:3px}'],
    ['firstLetter', '#bs2,::first-letter{letter-spacing:3px}'],
    ['functionalPart', '#bs2,::part(x){letter-spacing:3px}'],
    ['functionalSlotted', '#bs2,::slotted(x){letter-spacing:3px}'],
    ['cue', '#bs2,::cue{letter-spacing:3px}'],
    ['singleColonFirstLine', '#bs2,:first-line{letter-spacing:3px}'],
  ];
  for (const [label, css] of cases) {
    const sheet = document.createElement('style');
    sheet.textContent = css;
    document.head.appendChild(sheet);
    read(label);
    sheet.remove();
  }
  out.noRule = getComputedStyle(probe).letterSpacing;
  host.remove();
  return out;
})()
