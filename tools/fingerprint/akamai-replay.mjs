// Serves one captured Akamai interstitial back, from disk, so the challenge can
// be run against both engines without touching the real site.
//
//   node tools/fingerprint/akamai-replay.mjs --bodies results/b41-macys-bodies --port 10380
//   node tools/fingerprint/akamai-replay.mjs --bodies <dir> --port 10380 --inject probes/x.js
//
// The capture comes from `sensor-cpu-profile.mjs --body-dir`, which saves every
// response body of a real visit under a filename that spells its URL. This
// server maps those filenames back to paths and answers POSTs the way the site
// does: 201 `{"success":true}` for the sensor endpoint, 200 for the `?t=`
// challenge-id endpoint that the interstitial's inline poller is watching for.
// The sensor does not check either reply, which is why a capture keeps working
// long after the session that produced it is dead.
//
// HERMETIC OR IT IS NOT AN EXPERIMENT. The captured document loads its loader
// from an absolute `https://www.macys.com/...` URL, and the loader derives every
// module URL from its own `src`. Serve that document as-is and both arms go and
// fetch code from the live site -- which is how an earlier round of this work
// spent three sessions comparing two arms that were running *different
// programs*: one arm got five modules and ran them, the other got none. So
// every `https://www.macys.com/` in the document is rewritten to this server,
// and every request that arrives is logged: a run whose log does not account
// for every script the page executed is not a hermetic run, and its readings
// mean nothing.
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const arg = (name, fallback) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : fallback;
};
const bodies = path.resolve(repo, arg('--bodies', 'tools/fingerprint/results/b41-macys-bodies'));
const PORT = Number(arg('--port', 10380));
// Scripts to run before anything the page loads, so a probe can wrap a
// primitive before the guard's own code touches it. Repeatable.
const injects = process.argv.reduce((acc, a, i) => (
    a === '--inject' && process.argv[i + 1] ? [...acc, process.argv[i + 1]] : acc), []);
const quiet = process.argv.includes('--quiet');
// DO NOT REWRITE THE GUARD'S SOURCE TEXT. Tried and measured: marking each of
// the sensor script's 631 `case <ident>:` labels with a `__M(<offset>);` call,
// to trace which case bodies ran, produced a page that loads, runs 5986 marks
// in 52ms and then stops -- no sensor POST at all, in either engine. A regex
// over minified code cannot tell a `case` label from the same bytes inside a
// string literal, and the script hashes 496KB of its own source (see
// probes/probe-hash-work.js: `charCodeAt` runs 635k times over a 496239-char
// string) so it would notice regardless. Instrument from *outside* -- wrap
// globals with --inject -- or read the capture on disk.

// The capture's filenames are `NN-host_path_with_underscores`. Rather than
// invert that lossily, index by the tail of the name: a request is served by
// the file whose name ends with the request path's own underscored form.
const files = (await fs.readdir(bodies)).filter((f) => /^\d\d-/.test(f)).sort();
const table = [];
for (const f of files) {
    const key = f.slice(3);
    table.push({ file: f, key, body: await fs.readFile(path.join(bodies, f)) });
}
const doc = table.find((e) => /^www\.[\w.]+_$/.test(e.key));
if (!doc) throw new Error(`no document body in ${bodies} (expected a NN-host_ file)`);
const origin = doc.key.slice(0, -1);

const mime = (p) => (p.endsWith('.js') || /\/(public|Go-)/.test(p) ? 'application/javascript'
    : p.endsWith('.ico') ? 'image/x-icon'
        : p.endsWith('.svg') ? 'image/svg+xml' : 'text/html');

const underscored = (p) => p.replace(/^https?:\/\//, '').replace(/[^\w.=-]+/g, '_').slice(0, 90);

function lookup(reqPath) {
    const want = underscored(`${origin}${reqPath}`);
    // Exact first, then the same path without its query: the challenge script's
    // `?v=<uuid>&t=<id>` is regenerated per session and the capture's copy is
    // the only one there is.
    return table.find((e) => e.key === want)
        ?? table.find((e) => e.key === underscored(`${origin}${reqPath.split('?')[0]}`))
        ?? table.find((e) => e.key.startsWith(underscored(`${origin}${reqPath.split('?')[0]}`)));
}

let injected = '';
for (const f of injects) injected += `<script>${await fs.readFile(path.resolve(repo, f), 'utf8')}</script>\n`;

const log = [];
const server = http.createServer(async (req, res) => {
    const line = `${req.method} ${req.url}`;
    log.push(line);
    if (!quiet) console.log(line);
    const p = req.url;

    if (req.method === 'POST') {
        // Drain, and report the size: the payload length is the reading this
        // whole harness exists to compare, and its cleartext header carries the
        // guard's own collection counter.
        const chunks = [];
        for await (const c of req) chunks.push(c);
        const body = Buffer.concat(chunks).toString('utf8');
        const head = (body.match(/"sensor_data":"([^"]{0,80})/)?.[1] ?? body.slice(0, 60)).replace(/\\/g, '');
        console.log(`  POST ${chunks.reduce((n, c) => n + c.length, 0)}B  ${head}`);
        const t = /[?&]t=/.test(p);
        res.writeHead(t ? 200 : 201, { 'content-type': 'application/json' });
        res.end('{"success":true}');
        return;
    }

    const hit = lookup(p);
    if (!hit) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        res.end('not in capture');
        return;
    }
    let body = hit.body;
    if (hit === doc) {
        // The rewrite that makes the run hermetic, plus the probes.
        body = Buffer.from(String(body)
            .replaceAll(`https://${origin}/`, `http://127.0.0.1:${PORT}/`)
            .replace('<body>', `<body>\n${injected}`));
    }
    res.writeHead(200, { 'content-type': mime(p) });
    res.end(body);
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`replay of ${origin} on http://127.0.0.1:${PORT}/ — ${table.length} bodies from ${path.relative(repo, bodies)}`);
    if (injects.length) console.log(`injecting: ${injects.join(', ')}`);
});
process.on('SIGTERM', () => { server.close(); process.exit(0); });
