// A two-origin fixture on one port. `127.0.0.1` and `localhost` are the same
// machine and different origins, which is all a cross-origin subframe needs and
// is deterministic in a way a real station is not.
//
//   node probes/b86-subframe-fixture.mjs 8710
//
// The parent is loaded from 127.0.0.1 and frames the child from localhost.
// EACH FRAME FETCHES ITS OWN ORIGIN. That is the whole point of the fixture:
// a cross-origin resource has its connection milestones zeroed by the spec
// unless the server sends Timing-Allow-Origin, so fetching cross-origin would
// measure that rule instead of the question.
//
// Four initiator types, because they do not share a code path in this engine:
// Frame.recordResourceTiming's own comment says script/link/img go through it
// while "XHR and fetch call Performance directly", and only the former calls
// setConnectionMilestones. Measuring one initiator would have reported that
// split as a property of the frame.
import http from 'node:http';

const port = Number(process.argv[2] || 8710);

const COLLECT = `
const FIELDS = ['startTime','redirectStart','redirectEnd','fetchStart',
  'domainLookupStart','domainLookupEnd','connectStart','connectEnd',
  'secureConnectionStart','requestStart','responseStart','responseEnd'];
const NINE = ['fetchStart','domainLookupStart','domainLookupEnd','connectStart',
  'connectEnd','secureConnectionStart','requestStart','responseStart','responseEnd'];
function readAll(tag) {
  return performance.getEntriesByType('resource')
    .filter((e) => e.name.indexOf(tag) !== -1)
    .map((e) => {
      const o = { initiatorType: e.initiatorType,
                  zeros: NINE.filter((f) => e[f] === 0).join(',') || '(none)' };
      for (const f of FIELDS) o[f] = Math.round(e[f] * 10) / 10;
      return o;
    });
}
function loadFour(origin, tag) {
  const jobs = [];
  jobs.push(new Promise((r) => {
    const x = new XMLHttpRequest();
    x.open('GET', origin + '/ping?' + tag); x.onloadend = r; x.send();
  }));
  jobs.push(fetch(origin + '/fetch?' + tag).then((res) => res.text()).catch(() => {}));
  jobs.push(new Promise((r) => {
    const i = new Image(); i.onload = r; i.onerror = r; i.src = origin + '/img.gif?' + tag;
  }));
  jobs.push(new Promise((r) => {
    const s = document.createElement('script');
    s.onload = r; s.onerror = r; s.src = origin + '/s.js?' + tag;
    document.head.appendChild(s);
  }));
  return Promise.all(jobs);
}
`;

const PARENT = `<!DOCTYPE html>
<title>parent</title>
<body>
<script>
${COLLECT}
window.__collect = { readAll, loadFour };
window.__child = null;
addEventListener('message', (e) => { if (e.data && e.data.__milestones) window.__child = e.data; });
</script>
<iframe src="http://localhost:${port}/child.html"></iframe>
</body>`;

const CHILD = `<!DOCTYPE html>
<title>child</title>
<body>
<script>
${COLLECT}
loadFour('http://localhost:${port}', 'kid').then(() => setTimeout(() => {
  parent.postMessage({ __milestones: true, entries: readAll('kid') }, '*');
}, 400));
</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    const send = (type, body) => {
        res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
        res.end(body);
    };
    if (url === '/parent.html') return send('text/html', PARENT);
    if (url === '/child.html') return send('text/html', CHILD);
    if (url === '/img.gif') return send('image/gif', GIF);
    if (url === '/s.js') return send('application/javascript', '/* ' + 'x'.repeat(500) + ' */');
    if (url === '/ping' || url === '/fetch') return send('text/plain', 'x'.repeat(512));
    res.writeHead(404);
    res.end();
}).listen(port, () => console.log(`fixture on ${port}`));
