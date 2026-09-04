(() => {
  // The paths a stylesheet rule does not cover. The census in
  // probes/expr-b107-unitless-zero-census.js read every slot off
  // `sheet.cssRules[0].style`; a declaration also arrives through a `style`
  // attribute, through `setProperty`, and through an IDL attribute assignment,
  // and each is its own parse in this engine. Same three readings on both arms
  // decide whether a fix at the token walk covers all four.
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));

  const attr = document.createElement('div');
  attr.setAttribute('style', 'transform:rotate(0) translateY(0) scale(0)');
  document.body.appendChild(attr);

  const set = document.createElement('div');
  set.style.setProperty('transform', 'skewY(0) translateX(0) matrix(1,0,0,1,0,0)');
  document.body.appendChild(set);

  const idl = document.createElement('div');
  idl.style.transform = 'perspective(0) rotate3d(1,1,1,0)';
  document.body.appendChild(idl);

  // The computed value is a matrix whatever the list said, so this is a
  // regression reading rather than a serialisation one: an appended unit must
  // not change what the zero means.
  const computed = document.createElement('div');
  computed.style.transform = 'rotate(0) translateY(0)';
  document.body.appendChild(computed);

  return {
    attrProp: attr.style.transform,
    attrCss: attr.style.cssText,
    attrAttr: attr.getAttribute('style'),
    setProp: set.style.transform,
    setCss: set.style.cssText,
    idlProp: idl.style.transform,
    idlCss: idl.style.cssText,
    computedTransform: getComputedStyle(computed).transform,
  };
})()
