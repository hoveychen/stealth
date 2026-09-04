(() => {
  const out = { dpr: window.devicePixelRatio };
  // inline path
  const el = document.createElement('div');
  el.style.transform = 'rotate(0deg) translateY(0px) scale(1)';
  out.inline_cssText = el.style.cssText;
  out.inline_prop = el.style.transform;
  el.style.cssText = 'transform: rotate(0deg) translateY(0px)';
  out.inline_roundtrip = el.style.cssText;
  // stylesheet path
  const st = document.createElement('style');
  st.textContent = '@keyframes k { 0% { transform: rotate(2deg) translateY(2px); } 100% { transform: rotate(0deg) translateY(0px); } }\n#z { transform: rotate(0deg) translateY(0px); }';
  document.head.appendChild(st);
  const sheet = st.sheet;
  out.sheet_rules = Array.from(sheet.cssRules).map((r) => r.cssText);
  // a few more zero-unit shapes for the same family
  const e2 = document.createElement('div');
  e2.style.cssText = 'transform: skewX(0deg) rotate(0rad) translateX(0em) translateZ(0px)';
  out.other_units = e2.style.cssText;
  return out;
})()
