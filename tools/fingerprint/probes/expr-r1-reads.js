// The reads `fo-reads.mjs` saw the Turnstile widget make before its round-1
// POST, taken off the station and asked of both engines directly.
//
// Each row is a value the widget was handed in the widget realm and where the
// two arms answered differently; the station is not needed to check any of
// them, only a document.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-r1-reads.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-r1-reads.js
(() => {
  const out = {};
  const desc = (o, k) => {
    try {
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (!d) return 'absent';
      return { get: typeof d.get, set: typeof d.set, value: 'value' in d ? typeof d.value : undefined,
               enumerable: d.enumerable, configurable: d.configurable, writable: d.writable };
    } catch (e) { return 'THREW ' + e.name; }
  };

  // `about:blank` arrives here without a documentElement, so the probe makes
  // one rather than reporting a null-deref as the answer.
  out.hadDocumentElement = !!document.documentElement;
  if (!document.documentElement) document.appendChild(document.createElement('html'));

  // 1. innerText of an element that is not rendered. Per spec it falls back to
  //    textContent; the widget reads it off the `<style>` it just wrote.
  const style = document.createElement('style');
  style.textContent = '@keyframes spin{100%{transform:rotate(360deg)}}';
  document.documentElement.appendChild(style);
  out.styleInnerText = style.innerText;
  out.styleTextContent = style.textContent;

  const hidden = document.createElement('div');
  hidden.style.display = 'none';
  hidden.textContent = 'hello there';
  document.documentElement.appendChild(hidden);
  out.hiddenInnerText = hidden.innerText;

  // 2. classList as an object: Chrome's DOMTokenList carries indexed own
  //    properties, so JSON.stringify of one is not `{}`.
  const el = document.createElement('div');
  el.className = 'main-wrapper .tOHY4';
  out.classListJson = JSON.stringify(el.classList);
  out.classListOwn = Object.getOwnPropertyNames(el.classList).join(' ');
  out.classListLength = el.classList.length;
  out.classListIndex0 = el.classList[0];
  out.classListSpread = (() => { try { return [...el.classList].join('|'); } catch (e) { return 'THREW ' + e.name; } })();

  // 3. The descriptor kind of the self-referential globals. The read tracer
  //    could replace `window.window` here and not in Chrome, which is only
  //    possible if the two disagree about `configurable`.
  out.descWindow = desc(window, 'window');
  out.descSelf = desc(window, 'self');
  out.descTop = desc(window, 'top');
  out.descParent = desc(window, 'parent');
  out.descFrameElement = desc(window, 'frameElement');
  out.descLocation = desc(window, 'location');

  // 4. timeOrigin. Chrome's is epoch milliseconds, so origin + now() lands on
  //    Date.now(); a boot-relative origin does not.
  const origin = performance.timeOrigin;
  const now = performance.now();
  out.timeOrigin = origin;
  out.timeOriginIsEpoch = origin > 1700000000000 && origin < 4000000000000;
  out.originPlusNowVsDateNow = Math.round(origin + now - Date.now());
  out.nowSample = String(now);
  out.timingSecureConnectionStart = performance.timing.secureConnectionStart;
  out.timingConnectStart = performance.timing.connectStart;

  return JSON.stringify(out);
})()
