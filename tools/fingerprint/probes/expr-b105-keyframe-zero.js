(() => {
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  // The exact shapes the Turnstile widget's stylesheet uses, copied off the
  // live capture rather than invented: a zero followed by a NON-zero function,
  // and a lone zero translate.
  const st = document.createElement('style');
  st.textContent =
    '@keyframes a { 70% { transform: rotate(2deg) scale(1.06); opacity: 1; }\n' +
    '  100% { transform: rotate(0deg) scale(1); opacity: 1; } }\n' +
    '@keyframes b { 0% { transform: translateY(2px); opacity: 0; }\n' +
    '  100% { transform: translateY(0px); opacity: 1; } }\n' +
    '#k { transform: rotate(0deg) scale(1); }\n' +
    '#j { transform: translateY(0px); }';
  document.head.appendChild(st);
  const rules = Array.from(st.sheet.cssRules).map((r) => r.cssText);
  // inline, same two shapes
  const e = document.createElement('div');
  e.style.cssText = 'transform: rotate(0deg) scale(1)';
  const inline1 = e.style.cssText;
  e.style.cssText = 'transform: translateY(0px)';
  const inline2 = e.style.cssText;
  return { rules, inline1, inline2 };
})()
