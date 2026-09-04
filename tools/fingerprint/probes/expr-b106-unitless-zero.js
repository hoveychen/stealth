(() => {
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const st = document.createElement('style');
  // Written the way the station ships it: a UNITLESS zero.
  st.textContent = '@keyframes b106u{0%{transform:rotate(-12deg) scale(.6);opacity:0}' +
      '100%{transform:rotate(0) scale(1);opacity:1}}' +
      '@keyframes b106v{0%{transform:translateY(2px)}100%{transform:translateY(0)}}' +
      '#u{transform:rotate(0) scale(1)}#v{transform:translateY(0)}';
  document.head.appendChild(st);
  const sh = st.sheet;
  return {
    kfSteps: Array.from(sh.cssRules[0].cssRules).map((k) => k.keyText + '=' + k.style.transform),
    kfLone: Array.from(sh.cssRules[1].cssRules).map((k) => k.keyText + '=' + k.style.transform),
    plainU: sh.cssRules[2].cssText,
    plainV: sh.cssRules[3].cssText,
  };
})()
