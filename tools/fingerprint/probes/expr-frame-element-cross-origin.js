// What a cross-origin framed document is told about the element embedding it.
// The Turnstile widget is challenges.cloudflare.com inside the site's origin
// and Chrome hands it `null` there; this engine handed it the <iframe>.
//
// A `data:` document has an opaque origin, so it is cross-origin to its
// embedder without needing a second host to serve it.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-frame-element-cross-origin.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-frame-element-cross-origin.js
(async () => {
  if (!document.documentElement) document.appendChild(document.createElement('html'));
  const out = {};

  const ask = (src, key) => new Promise((resolve) => {
    const onMessage = (e) => {
      if (!e.data || e.data.t !== key) return;
      window.removeEventListener('message', onMessage);
      resolve(e.data);
    };
    window.addEventListener('message', onMessage);
    const iframe = document.createElement('iframe');
    iframe.src = src;
    document.documentElement.appendChild(iframe);
    setTimeout(() => resolve({ v: '<timeout>' }), 4000);
  });

  const report = "<script>parent.postMessage({t:'K',"
    + "v:String(window.frameElement),"
    + "tag:(window.frameElement&&window.frameElement.tagName)||'-',"
    + "threw:(function(){try{void window.frameElement;return 'no'}catch(e){return e.name}})()"
    + "},'*')<\/script>";

  const xorigin = await ask('data:text/html,' + encodeURIComponent(report.replace(/K/, 'x')), 'x');
  out.crossOriginFrameElement = xorigin.v;
  out.crossOriginTag = xorigin.tag;
  out.crossOriginThrew = xorigin.threw;

  // The same-origin control: an about:blank child inherits the embedder's
  // origin and must still see the element.
  const same = document.createElement('iframe');
  document.documentElement.appendChild(same);
  out.sameOriginFrameElement = String(same.contentWindow.frameElement);
  out.sameOriginIsTheIframe = same.contentWindow.frameElement === same;
  out.topFrameElement = String(window.frameElement);
  return JSON.stringify(out);
})()
