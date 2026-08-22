// Raw HTTP/2 echo server that records the wire header list of every stream.
//
// header-echo.mjs answers the h1 question, and cannot answer the h2 one: HPACK
// lowercases every field name, so a casing difference visible over h1 is gone
// here, and a field Chrome only sends over h2 -- the RFC 9218 `priority` hint --
// never shows up there at all. Real guards are reached over h2, so the
// comparison has to happen over h2.
//
// Serves the same page set as header-echo.mjs, imported rather than copied, so
// the two captures pull the same subresources and stay comparable.
import http2 from 'node:http2';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { body } from './header-echo.mjs';

// A throwaway self-signed cert, generated per run rather than committed: a key
// in the tree is a key in the tree, and openssl is already a build-host
// dependency. The SAN covers both spellings a browser might be pointed at.
export async function selfSignedCert() {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-h2-cert-'));
    const key = path.join(dir, 'key.pem');
    const cert = path.join(dir, 'cert.pem');
    await new Promise((resolve, reject) => {
        const p = spawn('openssl', [
            'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', key, '-out', cert, '-days', '1',
            '-subj', '/CN=localhost',
            '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
        let err = '';
        p.stderr.on('data', (d) => (err += d));
        p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`openssl exit ${code}: ${err}`))));
    });
    return { dir, key, cert, rm: () => fs.rm(dir, { recursive: true, force: true }).catch(() => {}) };
}

export async function startH2Echo(port, certFiles) {
    const records = [];
    const server = http2.createSecureServer({
        key: await fs.readFile(certFiles.key),
        cert: await fs.readFile(certFiles.cert),
        // So a client that declines h2 still lands in the capture, labelled,
        // rather than silently failing to connect and reading as "no requests".
        allowHTTP1: true,
    });

    // node:http2 hands the header block over as a flat array in wire order,
    // which is the part that matters: `headers` is a normalised object and has
    // already lost the ordering and any duplicate.
    server.on('stream', (stream, headers, flags, rawHeaders) => {
        const pairs = [];
        for (let i = 0; i < rawHeaders.length; i += 2) pairs.push([rawHeaders[i], rawHeaders[i + 1]]);
        records.push({ alpn: 'h2', method: headers[':method'], path: headers[':path'], headers: pairs });
        const [ctype, payload] = body(headers[':path']);
        stream.respond({ ':status': 200, 'content-type': ctype, 'cache-control': 'no-store' });
        stream.end(payload);
    });

    server.on('request', (req, res) => {
        // h2 streams arrive on 'stream' as well; only take the h1 fallback here.
        if (req.httpVersionMajor >= 2) return;
        const pairs = [];
        for (let i = 0; i < req.rawHeaders.length; i += 2) pairs.push([req.rawHeaders[i], req.rawHeaders[i + 1]]);
        records.push({ alpn: 'http/1.1', method: req.method, path: req.url, headers: pairs });
        const [ctype, payload] = body(req.url);
        res.writeHead(200, { 'content-type': ctype, 'cache-control': 'no-store' });
        res.end(payload);
    });

    return new Promise((resolve) => {
        server.listen(port, '127.0.0.1', () =>
            resolve({
                records,
                port: server.address().port,
                close: () => new Promise((r) => {
                    server.close(() => r());
                    // TLS keep-alive sessions outlive close(), which otherwise
                    // waits on them forever. Same trap as header-echo.mjs.
                    server.closeAllConnections?.();
                }),
            }));
    });
}
