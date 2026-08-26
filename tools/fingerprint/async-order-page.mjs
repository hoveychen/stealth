// Serves the three pages that tell a queued async-script task from an inline
// call, because one page cannot.
//
//   node tools/fingerprint/async-order-page.mjs --variant inflight|delayed|slow --port N
//   PORT=M node tools/fingerprint/run-expr.mjs lightpanda|chrome \
//     tools/fingerprint/probes/expr-async-script-order.js --url http://127.0.0.1:N/
//
// All three variants have the same document -- an `async` script between two
// parser-blocking ones -- and differ only in when the async script's bytes
// arrive:
//
//   inflight  both scripts served instantly, so both are still in flight when
//             the parser blocks on the second one. The async script wins the
//             race and runs first. Both arms agree.
//   delayed   the async response is held 250ms, so it lands long after the
//             parse. It runs last. Both arms agree.
//   slow      the first blocking script busy-loops 300ms, so the async script's
//             fetch finishes while the parser is still inside it and both later
//             scripts are cached by the time the parser resumes. Chrome runs the
//             async script LAST; this engine used to run it second, because
//             adopting a completed prescan fetch called evaluate() inside the
//             parser. That is the only variant that separates the two, and it is
//             the shape Akamai's interstitial ships.
//
// The regression test for the fixed behaviour is
// src/browser/tests/script_async_order.html; this server is what finds the next
// one, since it can move the timing that the fixture has to hold still.
import http from 'node:http';

const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const variant = arg('--variant', 'slow');
const port = Number(arg('--port', 10840));
if (!['inflight', 'delayed', 'slow'].includes(variant)) {
    console.error('usage: async-order-page.mjs --variant inflight|delayed|slow [--port N]');
    process.exit(2);
}

const slowTag = variant === 'slow' ? '<script src="/slow-blocking.js"></script>\n' : '';
const page = `<!DOCTYPE html><html><body>
<script>window.__o = [];</script>
${slowTag}<script src="/a-async.js" async></script>
<script src="/b-blocking.js"></script>
<script>window.__o.push('inline-after-blocking');</script>
</body></html>`;

const bodies = {
    '/slow-blocking.js': "window.__o.push('slow-start');var t=Date.now();while(Date.now()-t<300);window.__o.push('slow-end');",
    '/a-async.js': "window.__o.push('a-async');",
    '/b-blocking.js': "window.__o.push('b-blocking');",
};

http.createServer((req, res) => {
    if (req.url === '/') {
        res.writeHead(200, { 'content-type': 'text/html' });
        return res.end(page);
    }
    const body = bodies[req.url];
    if (!body) {
        res.writeHead(404);
        return res.end();
    }
    const send = () => {
        res.writeHead(200, { 'content-type': 'text/javascript' });
        res.end(body);
    };
    // Held, not slow to generate: the question is when the bytes land relative
    // to the parser, and a delay on the response is the only way to put the
    // async script's arrival after the parse rather than during it.
    if (req.url === '/a-async.js' && variant === 'delayed') setTimeout(send, 250);
    else send();
}).listen(port, '127.0.0.1', () => console.log(`async-order-page ${variant} on http://127.0.0.1:${port}/`));
