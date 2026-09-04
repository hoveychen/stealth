// What decides whether an `<img>` fires `load` or `error`: the status code, the
// declared Content-Type, or the bytes? Serves one fixture per hypothesis from a
// local server and asks an engine which event each one produces.
//
//   node tools/fingerprint/img-sniff.mjs chrome
//   node tools/fingerprint/img-sniff.mjs lightpanda
//
// Diff the two outputs and the answer is the diff. The fixtures vary the three
// inputs independently -- same PNG bytes under four different Content-Types and
// under a 404, the same SVG bytes under four, HTML bytes dressed as
// `image/png` -- which is what separates "it sniffed the body" from "it trusted
// the header" from "it trusted the status".
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, goto, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
if (engine !== 'chrome' && engine !== 'lightpanda') {
    console.error('usage: img-sniff.mjs <lightpanda|chrome>');
    process.exit(1);
}

// The same one-pixel PNG the test server serves (`ONE_PIXEL_PNG` in
// src/testing.zig), so a reading here is comparable to one from `make test`.
const PNG = Buffer.from(
    '89504e470d0a1a0a0000000d494844520000000100000001080600' +
    '00001f15c4890000000d4944415478da63fccfc0500f0004850180' +
    '84a98c210000000049454e44ae426082',
    'hex',
);
const SVG = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"></svg>');
const HTML = Buffer.from('<html><body>not a picture</body></html>');

// name -> [status, Content-Type (null omits the header entirely), body]
const FIXTURES = {
    'png-image-png': [200, 'image/png', PNG],
    'png-octet-stream': [200, 'application/octet-stream', PNG],
    'png-text-html': [200, 'text/html', PNG],
    'png-no-content-type': [200, null, PNG],
    'png-truncated-4': [200, 'image/png', PNG.subarray(0, 4)],
    'png-truncated-12': [200, 'image/png', PNG.subarray(0, 12)],
    'png-empty-body': [200, 'image/png', Buffer.alloc(0)],
    'html-text-html': [200, 'text/html', HTML],
    'html-image-png': [200, 'image/png', HTML],
    'svg-image-svg': [200, 'image/svg+xml', SVG],
    'svg-text-plain': [200, 'text/plain', SVG],
    'svg-no-content-type': [200, null, SVG],
    'svg-octet-stream': [200, 'application/octet-stream', SVG],
    'png-status-404': [404, 'image/png', PNG],
    'png-status-500': [500, 'image/png', PNG],
    'png-status-204': [204, 'image/png', Buffer.alloc(0)],
};

const server = http.createServer((req, res) => {
    // The page the images are loaded from: about:blank has no body in every
    // engine, and a real document also puts the fixtures same-origin.
    if (req.url === '/host.html') {
        const page = '<!DOCTYPE html><title>img-sniff</title><body></body>';
        res.writeHead(200, {
            'Content-Type': 'text/html',
            'Content-Length': String(Buffer.byteLength(page)),
        });
        res.end(page);
        return;
    }
    const name = req.url.slice(1).split('?')[0].replace(/\.[a-z]+$/, '');
    const fixture = FIXTURES[name];
    if (!fixture) {
        res.writeHead(404).end('no such fixture');
        return;
    }
    const [status, type, body] = fixture;
    // Node would add its own Content-Type otherwise, and dropping the header
    // entirely is the whole point of the no-content-type fixtures.
    const headers = { 'Content-Length': String(body.length) };
    if (type) headers['Content-Type'] = type;
    res.writeHead(status, headers);
    res.end(status === 204 ? undefined : body);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const ORIGIN = `http://127.0.0.1:${server.address().port}`;

const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP_BIN = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const PORT = Number(process.env.PORT) || (engine === 'chrome' ? 9366 : 9367);

let proc;
if (engine === 'chrome') {
    const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'img-sniff-chrome-'));
    proc = spawn(CHROME, [
        `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check', ...personaScaleFlags(),
        '--headless=new',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP_BIN, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], {
        stdio: ['ignore', 'pipe', 'pipe'],
    });
}
const log = [];
proc.stdout.on('data', (d) => log.push(String(d)));
proc.stderr.on('data', (d) => log.push(String(d)));

// One image at a time, each awaited to settle: a fixture's answer is only
// meaningful next to the fixture it differs from by one input.
const expr = `(async () => {
  const origin = ${JSON.stringify(ORIGIN)};
  const names = ${JSON.stringify(Object.keys(FIXTURES))};
  const out = {};
  for (const name of names) {
    const img = document.createElement('img');
    document.body.appendChild(img);
    const event = await new Promise((resolve) => {
      img.addEventListener('load', () => resolve('load'));
      img.addEventListener('error', () => resolve('error'));
      setTimeout(() => resolve('timeout'), 3000);
      img.src = origin + '/' + name + '.png';
    });
    out[name] = {
      event: event,
      complete: img.complete,
      naturalWidth: img.naturalWidth,
      naturalHeight: img.naturalHeight,
      width: img.width,
      height: img.height,
    };
    img.remove();
  }
  return JSON.stringify(out);
})()`;

try {
    let version = null;
    for (let i = 0; i < 100; i++) {
        try {
            version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
            break;
        } catch {
            await sleep(200);
        }
    }
    if (!version) throw new Error(`${engine} CDP never came up\n${log.join('')}`);

    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    let sessionId;
    if (engine === 'chrome') {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    } else {
        const { browserContextId } = await cdp.send('Target.createBrowserContext');
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
        ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
    }

    await goto(cdp, sessionId, `${ORIGIN}/host.html`, { settleMs: 0 });

    const res = await cdp.send('Runtime.evaluate', {
        expression: expr,
        returnByValue: true,
        awaitPromise: true,
    }, sessionId);
    if (res.exceptionDetails) {
        console.error(JSON.stringify(res.exceptionDetails, null, 2));
        process.exitCode = 1;
    } else {
        const rows = JSON.parse(res.result.value);
        console.log(JSON.stringify({
            engine,
            user_agent: version['User-Agent'],
            fixtures: rows,
        }, null, 2));
    }
} finally {
    proc.kill('SIGKILL');
    server.close();
}
