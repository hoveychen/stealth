// The one header a preload's destination needs that HTTP/1.1 cannot show:
// RFC 9218 `priority`.
//
//   node tools/fingerprint/probes/b87-preload-priority-h2.mjs 8770
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-preload-as.js \
//        --url https://127.0.0.1:8770/page.html
//
// b87-preload-as-fixture.mjs answers every other question about
// `<link rel=preload as=...>` and cannot answer this one: Chrome sends the hint
// only over h2/h3, and node's `http` is h1. So this is the same page over h2,
// and nothing else -- the shared h2-echo.mjs serves header-echo.mjs's page set,
// which is a different capture and not ours to change.
//
// The certificate is throwaway and generated per run by h2-echo.mjs's helper;
// both engines are launched with certificate errors ignored by run-expr.mjs's
// --insecure handling, so an h2 reading costs no more setup than an h1 one.
import http2 from 'node:http2';
import { selfSignedCert } from '../h2-echo.mjs';

const port = Number(process.argv[2] || 8770);

const AS = ['image', 'style', 'script', 'font', 'fetch'];
const ext = (a) => (a === 'image' ? 'gif' : a === 'style' ? 'css' : a === 'script' ? 'js' : 'bin');

const PAGE = `<!DOCTYPE html>
<title>preload priority</title>
${AS.map((a) => `<link rel="preload" as="${a}" href="/p-${a}.${ext(a)}"${a === 'font' ? ' crossorigin' : ''}>`).join('\n')}
<body>
<script>window.__done = new Promise((r) => setTimeout(() => r(true), 900));</script>
</body>`;

const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');

const { key, cert } = await selfSignedCert();
// Printed so the engine under test can be pointed at it: this fork verifies
// certificates, and `lightpanda --ca-cert <path>` is how a throwaway one is
// made trustworthy for one run.
console.log(`cert: ${cert}`);
const fs = await import('node:fs/promises');

http2
    .createSecureServer({ key: await fs.readFile(key), cert: await fs.readFile(cert) })
    .on('stream', (stream, headers) => {
        const url = (headers[':path'] || '').split('?')[0];
        if (url === '/page.html') {
            console.log('--- navigation ---');
            stream.respond({ ':status': 200, 'content-type': 'text/html', 'cache-control': 'no-store' });
            return void stream.end(PAGE);
        }
        console.log(
            `  ${url.padEnd(14)} dest=${headers['sec-fetch-dest'] ?? '(none)'}` +
            `  prio=${headers.priority ?? '(none)'}`,
        );
        const type = url.endsWith('.gif') ? 'image/gif'
            : url.endsWith('.css') ? 'text/css'
                : url.endsWith('.js') ? 'application/javascript' : 'application/octet-stream';
        stream.respond({
            ':status': 200,
            'content-type': type,
            'cache-control': 'no-store',
            'access-control-allow-origin': '*',
        });
        stream.end(url.endsWith('.gif') ? GIF : 'x'.repeat(64));
    })
    .listen(port, () => console.log(`preload priority (h2) on ${port}`));
