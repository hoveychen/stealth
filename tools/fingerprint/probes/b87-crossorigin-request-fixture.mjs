// What the `crossorigin` attribute changes about the REQUEST, measured rather
// than read off the spec: two ports so the loads are genuinely cross-origin,
// and the far server prints the headers that arrived.
//
//   node tools/fingerprint/probes/b87-crossorigin-request-fixture.mjs 8740 8741
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-request-headers.js \
//        --url http://127.0.0.1:8740/page.html
//
// Each row is a load kind crossed with the attribute's three states: absent,
// `anonymous`, `use-credentials`. The last one is the interesting one for
// cookies -- the attribute is not only about the Origin header.
//
// A cookie is set on the far origin first (via an <img> that the page waits
// for) so "were credentials sent" has a visible answer on every later row.
import http from 'node:http';

const [selfPort, otherPort] = [Number(process.argv[2] || 8740), Number(process.argv[3] || 8741)];
// `localhost` rather than another port on 127.0.0.1: a different port is
// cross-ORIGIN but same-SITE, and the credentials half of `crossorigin` is
// about cross-site cookies. Same machine either way.
const OTHER = `http://localhost:${otherPort}`;

const ROWS = [
    ['script', '', 'plain'],
    ['script', ' crossorigin', 'anon'],
    ['script', ' crossorigin="use-credentials"', 'creds'],
    ['img', '', 'plain'],
    ['img', ' crossorigin', 'anon'],
    ['img', ' crossorigin="use-credentials"', 'creds'],
    ['link', '', 'plain'],
    ['link', ' crossorigin', 'anon'],
    // A module script is CORS mode by construction -- no attribute needed --
    // if the spec is being followed. Measured rather than assumed, because it
    // decides whether `crossorigin` is the only thing that flips the mode.
    ['script', ' type="module"', 'mod'],
    ['script', ' type="module" crossorigin', 'mod-anon'],
];

const tag = (kind, attr, name) => {
    const url = `${OTHER}/${kind}-${name}.${kind === 'img' ? 'gif' : kind === 'link' ? 'css' : 'js'}`;
    if (kind === 'script') return `<script${attr} src="${url}"></` + `script>`;
    if (kind === 'img') return `<img${attr} src="${url}">`;
    return `<link rel="stylesheet"${attr} href="${url}">`;
};

// The same two states again, but same-origin, so "does the attribute change
// anything when there is no other origin involved" is answered rather than
// assumed.
const SAME_ROWS = [
    ['script', '', 'same-plain'],
    ['script', ' crossorigin', 'same-anon'],
    ['img', '', 'same-plain'],
    ['img', ' crossorigin', 'same-anon'],
];
const sameTag = (kind, attr, name) => {
    const url = `/${kind}-${name}.${kind === 'img' ? 'gif' : 'js'}`;
    if (kind === 'script') return `<script${attr} src="${url}"></` + `script>`;
    return `<img${attr} src="${url}">`;
};

const PAGE = `<!DOCTYPE html>
<title>crossorigin request</title>
${ROWS.map(([k, a, n]) => tag(k, a, n)).join('\n')}
${SAME_ROWS.map(([k, a, n]) => sameTag(k, a, n)).join('\n')}
<body>
<script>
// A second round, after the first has set the far origin's cookie. The first
// round cannot show the credentials difference: its requests all go out before
// any Set-Cookie has come back, so every row reads cookie=(none) whatever the
// attribute says. Round two is where anonymous and use-credentials part.
window.__done = new Promise((resolve) => setTimeout(() => {
  let left = 0;
  const bump = () => { if (--left === 0) setTimeout(() => resolve(true), 250); };
  for (const [kind, attr, name] of ${JSON.stringify(ROWS)}) {
    left++;
    const url = '${OTHER}/r2-' + kind + '-' + name + (kind === 'img' ? '.gif' : kind === 'link' ? '.css' : '.js');
    let el;
    if (kind === 'img') { el = document.createElement('img'); el.src = url; }
    else if (kind === 'link') { el = document.createElement('link'); el.rel = 'stylesheet'; el.href = url; }
    else { el = document.createElement('script'); el.src = url; }
    if (attr) el.crossOrigin = attr.indexOf('use-credentials') !== -1 ? 'use-credentials' : 'anonymous';
    el.onload = bump; el.onerror = bump;
    document.body.appendChild(el);
  }
  if (left === 0) resolve(true);
}, 500));
</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

const logHeaders = (req, label) => {
    const h = req.headers;
    console.log([
        label.padEnd(24),
        'origin=' + (h.origin ?? '(none)'),
        'mode=' + (h['sec-fetch-mode'] ?? '(none)'),
        'site=' + (h['sec-fetch-site'] ?? '(none)'),
        'dest=' + (h['sec-fetch-dest'] ?? '(none)'),
        'cookie=' + (h.cookie ?? '(none)'),
    ].join('  '));
};

http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/page.html') {
        res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' });
        return void res.end(PAGE);
    }
    // The same-origin half. `crossorigin` on a same-origin subresource is not
    // a no-op question: it puts the load in CORS mode, and whether Chrome then
    // states that in Sec-Fetch-Mode (and whether it appends an Origin, which
    // Fetch's own rule skips for a same-origin GET) is a reading, not
    // something to infer from the cross-origin rows.
    logHeaders(req, 'SAME' + url);
    const type = url.endsWith('.gif') ? 'image/gif' : url.endsWith('.css') ? 'text/css' : 'application/javascript';
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(url.endsWith('.gif') ? GIF : url.endsWith('.css') ? 'body{color:#111}' : 'void 0;');
}).listen(selfPort, () => console.log(`page origin on ${selfPort}`));

http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    const h = req.headers;
    console.log([
        url.padEnd(20),
        'origin=' + (h.origin ?? '(none)'),
        'mode=' + (h['sec-fetch-mode'] ?? '(none)'),
        'site=' + (h['sec-fetch-site'] ?? '(none)'),
        'dest=' + (h['sec-fetch-dest'] ?? '(none)'),
        'cookie=' + (h.cookie ?? '(none)'),
    ].join('  '));
    const type = url.endsWith('.gif') ? 'image/gif' : url.endsWith('.css') ? 'text/css' : 'application/javascript';
    res.writeHead(200, {
        'content-type': type,
        'cache-control': 'no-store',
        // Permissive on purpose: a refusal would change WHICH requests complete
        // and muddy the reading, and the question here is what went out.
        'access-control-allow-origin': `http://127.0.0.1:${selfPort}`,
        'access-control-allow-credentials': 'true',
        'set-cookie': 'far=1; Path=/; SameSite=None',
    });
    res.end(url.endsWith('.gif') ? GIF : url.endsWith('.css') ? 'body{color:#111}' : 'void 0;');
}).listen(otherPort, () => console.log(`other origin on ${otherPort}`));
