// Documents with no browsing context, read on a headed Chrome. Image fetches
// are judged from the access log of an image server on :18772
// (python3 -m http.server 18772 in a directory holding a file named dummy).
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-frameless-img.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:<port>/page.html'
(async () => {
  const out = {};
  const IMG = 'http://127.0.0.1:18772/dummy?case=';
  const hd = document.implementation.createHTMLDocument('t');
  const a = hd.createElement('img');
  const ev = [];
  a.onload = () => ev.push('load'); a.onerror = () => ev.push('error');
  a.src = IMG + 'a-frameless';
  out.completeSync = a.complete;
  const b = hd.createElement('img'); b.src = IMG + 'b-adopted';
  const bev = []; b.onload = () => bev.push('load'); b.onerror = () => bev.push('error');
  const c = hd.createElement('img'); c.src = IMG + 'c-adopted-connected';
  const t = document.createElement('template'); t.innerHTML = '<img src="' + IMG + 'd-template-imported">';
  await new Promise((r) => setTimeout(r, 300));
  out.completeLater = a.complete; out.naturalWidth = a.naturalWidth; out.events = ev.join(',');
  out.currentSrc = a.currentSrc;
  document.adoptNode(b);
  document.documentElement.appendChild(document.adoptNode(c));
  document.importNode(t.content, true);
  await new Promise((r) => setTimeout(r, 500));
  out.bEvents = bev.join(','); out.bComplete = b.complete;
  c.remove();
  return out;
})()
