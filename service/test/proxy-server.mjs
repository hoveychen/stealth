// Forward proxies for the end-to-end test: HTTP (absolute-URI requests and
// CONNECT tunnels) and SOCKS5, each optionally asking for a username and
// password, and each recording what went through it in `log`.
//
// `broken: true` makes an HTTP proxy that accepts the TCP connection and then
// answers every request with 502, the way a dead upstream behind a live
// proxy port looks.

import http from 'node:http';
import net from 'node:net';

// auth is "user:pass" or undefined.
export function startHttpProxy({ host = '127.0.0.1', port = 0, auth, broken = false } = {}) {
    const log = [];
    const expected = auth ? `Basic ${Buffer.from(auth).toString('base64')}` : null;
    const authorize = (req) => {
        if (!expected) return 'none';
        const got = req.headers['proxy-authorization'];
        if (!got) return 'missing';
        return got === expected ? 'ok' : 'bad';
    };
    const DENY = 'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="test"\r\nContent-Length: 0\r\n\r\n';

    const server = http.createServer((req, res) => {
        const a = authorize(req);
        log.push({ method: req.method, target: req.url, auth: a });
        if (broken) {
            res.writeHead(502, { 'content-type': 'text/plain' });
            return res.end('broken proxy');
        }
        if (a === 'missing' || a === 'bad') {
            res.writeHead(407, { 'proxy-authenticate': 'Basic realm="test"', 'content-type': 'text/plain' });
            return res.end('proxy auth required');
        }
        let target;
        try {
            target = new URL(req.url);
        } catch {
            res.writeHead(400);
            return res.end('absolute URL expected');
        }
        const headers = { ...req.headers };
        delete headers['proxy-authorization'];
        delete headers['proxy-connection'];
        const up = http.request({ host: target.hostname, port: target.port || 80, method: req.method, path: target.pathname + target.search, headers }, (r) => {
            res.writeHead(r.statusCode, r.headers);
            r.pipe(res);
        });
        up.on('error', () => {
            if (!res.headersSent) res.writeHead(502);
            res.end();
        });
        req.pipe(up);
    });
    server.on('connect', (req, sock, head) => {
        const a = authorize(req);
        log.push({ method: 'CONNECT', target: req.url, auth: a });
        if (broken) return sock.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n');
        if (a === 'missing' || a === 'bad') return sock.end(DENY);
        const [h, p] = req.url.split(':');
        let open = false;
        const up = net.connect(Number(p) || 443, h, () => {
            open = true;
            sock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            if (head.length) up.write(head);
            up.pipe(sock);
            sock.pipe(up);
        });
        // A target it can't reach gets a 502, as from squid or tinyproxy.
        up.on('error', () => (open ? sock.destroy() : sock.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')));
        sock.on('error', () => up.destroy());
    });
    return listen(server, host, port, log);
}

// RFC 1928 CONNECT only, with RFC 1929 username/password when auth is set.
export function startSocksProxy({ host = '127.0.0.1', port = 0, auth } = {}) {
    const log = [];
    const server = net.createServer((sock) => {
        sock.on('error', () => {});
        let buf = Buffer.alloc(0);
        let stage = 'greet';
        let authState = auth ? 'missing' : 'none';
        const need = (n) => buf.length >= n;
        const take = (n) => {
            const b = buf.subarray(0, n);
            buf = buf.subarray(n);
            return b;
        };
        const onData = (chunk) => {
            buf = Buffer.concat([buf, chunk]);
            for (;;) {
                if (stage === 'greet') {
                    if (!need(2) || !need(2 + buf[1])) return;
                    const methods = [...take(2 + buf[1]).subarray(2)];
                    const want = auth ? 0x02 : 0x00;
                    if (!methods.includes(want)) {
                        log.push({ method: 'SOCKS', target: null, auth: 'missing' });
                        return sock.end(Buffer.from([5, 0xff]));
                    }
                    sock.write(Buffer.from([5, want]));
                    stage = auth ? 'auth' : 'request';
                } else if (stage === 'auth') {
                    if (!need(2)) return;
                    const ulen = buf[1];
                    if (!need(3 + ulen) || !need(3 + ulen + buf[2 + ulen])) return;
                    const plen = buf[2 + ulen];
                    const b = take(3 + ulen + plen);
                    const given = `${b.subarray(2, 2 + ulen)}:${b.subarray(3 + ulen)}`;
                    authState = given === auth ? 'ok' : 'bad';
                    if (authState === 'bad') {
                        log.push({ method: 'SOCKS', target: null, auth: 'bad' });
                        return sock.end(Buffer.from([1, 1]));
                    }
                    sock.write(Buffer.from([1, 0]));
                    stage = 'request';
                } else if (stage === 'request') {
                    if (!need(5)) return;
                    const atyp = buf[3];
                    const alen = atyp === 1 ? 4 : atyp === 4 ? 16 : 1 + buf[4];
                    if (!need(4 + alen + 2)) return;
                    const b = take(4 + alen + 2);
                    let dst;
                    if (atyp === 1) dst = [...b.subarray(4, 8)].join('.');
                    else if (atyp === 3) dst = b.subarray(5, 5 + b[4]).toString();
                    else dst = b.subarray(4, 20).toString('hex').match(/.{4}/g).join(':');
                    const dport = b.readUInt16BE(4 + alen);
                    log.push({ method: 'SOCKS', target: `${dst}:${dport}`, auth: authState });
                    sock.removeListener('data', onData);
                    const up = net.connect(dport, dst, () => {
                        sock.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));
                        if (buf.length) up.write(buf);
                        up.pipe(sock);
                        sock.pipe(up);
                    });
                    up.on('error', () => sock.end(Buffer.from([5, 5, 0, 1, 0, 0, 0, 0, 0, 0])));
                    return;
                }
            }
        };
        sock.on('data', onData);
    });
    return listen(server, host, port, log);
}

function listen(server, host, port, log) {
    return new Promise((resolve, reject) => {
        server.on('error', reject);
        server.listen(port, host, 1024, () => resolve({ server, log, port: server.address().port }));
    });
}
