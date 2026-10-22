// When an `<iframe src="javascript:...">` runs its script, relative to a timer
// the inserting page set straight afterwards. Each case logs who ran first; the
// busy cases hold the page's thread past the timer's due time before yielding.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-jsurl-iframe-order.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:<port>/page.html'
(async () => {
  const busy = (ms) => { const end = performance.now() + ms; while (performance.now() < end); };
  const one = (delay, busyMs) => new Promise((resolve) => {
    const log = [];
    window.__jsurlLog = log;
    const f = document.createElement('iframe');
    f.src = "javascript:parent.__jsurlLog.push('frame:' + (self === parent ? 'parent' : 'frame'))";
    document.body.appendChild(f);
    log.push('sync:' + (f.contentWindow.__never === undefined));
    setTimeout(() => {
      log.push('timer');
      setTimeout(() => { f.remove(); resolve(log.join(',')); }, 50);
    }, delay);
    if (busyMs) busy(busyMs);
  });
  const out = {};
  for (const [name, d, b] of [['t0', 0, 0], ['t10', 10, 0], ['t0_busy20', 0, 20], ['t10_busy20', 10, 20], ['t10_busy50', 10, 50]]) {
    const runs = [];
    for (let i = 0; i < 5; i++) runs.push(await one(d, b));
    out[name] = [...new Set(runs)].join(' | ');
  }
  return out;
})()
