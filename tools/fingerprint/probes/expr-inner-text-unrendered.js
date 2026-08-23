// `innerText` on things that are not rendered. The spec's first step is "if
// this is not being rendered, return this's descendant text content", and the
// Turnstile widget reads it off the `<style>` element it has just written --
// where this engine answered `""` and Chrome answered the CSS.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-inner-text-unrendered.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-inner-text-unrendered.js
(() => {
  const out = {};
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));
  const body = document.body;

  const put = (name, el) => { body.appendChild(el); out[name] = el.innerText; };

  const style = document.createElement('style');
  style.textContent = '.a{color:red}';
  put('styleInBody', style);

  const script = document.createElement('script');
  script.type = 'application/json';
  script.textContent = '{"a":1}';
  put('scriptInBody', script);

  const tpl = document.createElement('template');
  tpl.innerHTML = 'templated';
  out.templateInBody = (body.appendChild(tpl), tpl.innerText);

  const noscript = document.createElement('noscript');
  noscript.textContent = 'no script here';
  put('noscriptInBody', noscript);

  const hidden = document.createElement('div');
  hidden.style.display = 'none';
  hidden.textContent = 'hidden text';
  put('displayNoneInBody', hidden);

  const invisible = document.createElement('div');
  invisible.style.visibility = 'hidden';
  invisible.textContent = 'invisible text';
  put('visibilityHiddenInBody', invisible);

  const detached = document.createElement('div');
  detached.textContent = 'detached text';
  out.detached = detached.innerText;

  const shown = document.createElement('div');
  shown.textContent = 'shown text';
  put('plainInBody', shown);

  out.head = document.head ? document.head.innerText : '<no head>';

  // Both halves of the comparison, so a "" can be told from an element that
  // genuinely had no text.
  out.styleTextContent = style.textContent;
  out.headTextContentLen = document.head ? document.head.textContent.length : -1;
  return JSON.stringify(out);
})()
