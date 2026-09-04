(() => {
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const st = document.createElement('style');
  st.textContent = '@keyframes b106 { \n' +
      '  0% { transform: rotate(-12deg) scale(0.6); opacity: 0; }\n' +
      '  70% { transform: rotate(2deg) scale(1.06); opacity: 1; }\n' +
      '  100% { transform: rotate(0deg) scale(1); opacity: 1; }\n}\n' +
      '@keyframes b106b { 0% { transform: translateY(2px); } 100% { transform: translateY(0px); } }';
  document.head.appendChild(st);
  const kf = st.sheet.cssRules[0];
  const kf2 = st.sheet.cssRules[1];
  return {
    wholeCssText: kf.cssText,
    steps: Array.from(kf.cssRules).map((k) => ({
      key: k.keyText,
      styleTransform: k.style.transform,
      styleCssText: k.style.cssText,
      cssText: k.cssText,
    })),
    lone: Array.from(kf2.cssRules).map((k) => ({ key: k.keyText, styleTransform: k.style.transform })),
  };
})()
