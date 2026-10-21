// Proxies: validating a proxy URL, a rotating pool with temporary ejection of
// proxies that keep failing, and telling a proxy's failure apart from the
// target's (and a wrong password from a dead proxy).
//
// The engine hands the proxy URL to libcurl as is (Target.createBrowserContext
// proxyServer), and libcurl sends credentials from the URL preemptively:
// http://user:pass@host:port authenticates without any CDP round trip.

import net from 'node:net';
import tls from 'node:tls';

// http, https (TLS to the proxy) and socks5/socks5h are verified end to end.
export const PROXY_SCHEMES = ['http:', 'https:', 'socks5:', 'socks5h:'];

// Throws an Error whose message is fit for a 400 (password redacted).
export function normalizeProxyUrl(raw) {
    if (typeof raw !== 'string' || raw === '') throw new Error('proxy must be a URL string');
    let u;
    try {
        u = new URL(raw);
    } catch {
        throw new Error(`proxy is not a valid URL: ${redact(raw)}`);
    }
    if (!PROXY_SCHEMES.includes(u.protocol)) throw new Error(`proxy scheme must be one of ${PROXY_SCHEMES.map((s) => s.slice(0, -1)).join(', ')}`);
    if (!u.hostname || !u.port) throw new Error(`proxy needs a host and a port: ${redact(raw)}`);
    if (u.pathname !== '/' && u.pathname !== '') throw new Error(`proxy must not have a path: ${redact(raw)}`);
    // Not u.href: that would percent-encode differently from what was given,
    // and libcurl decodes the userinfo itself.
    return raw.replace(/\/$/, '');
}

// The URL with the password replaced, for logs, errors and /health.
export function redact(url) {
    return String(url).replace(/^([a-z0-9+.-]+:\/\/[^:/@]*:)[^@/]*@/i, '$1***@');
}

// Engine error texts (Page.navigate errorText / Network.loadingFailed) that
// mean the proxy could not be used: unreachable, unresolvable, a SOCKS
// handshake failure, or a CONNECT the proxy refused. TLS errors are left out:
// they are the target's certificate as often as an https proxy's. Through an
// HTTP proxy an unreachable *target* comes back as the proxy's own 502 page
// for http URLs, but as a refused CONNECT (CouldntConnect) for https URLs, the
// same text as a dead proxy; diagnoseProxyFailure tells the two apart.
const PROXY_ERRORS = new Set(['CouldntConnect', 'CouldntResolveProxy', 'Proxy']);
export const isProxyError = (errorText) => PROXY_ERRORS.has(errorText);

export class ProxyPool {
    // urls: normalized proxy URLs. A proxy is ejected after `maxFails`
    // consecutive failures and is offered again `retryAfterMs` later; one more
    // failure then ejects it again straight away.
    constructor(urls, { maxFails = 3, retryAfterMs = 60000, now = Date.now } = {}) {
        this.maxFails = maxFails;
        this.retryAfterMs = retryAfterMs;
        this.now = now;
        this.next = 0;
        this.entries = [...new Set(urls)].map((url) => ({ url, name: redact(url), uses: 0, ok: 0, failed: 0, consecutiveFails: 0, ejectedUntil: 0, lastError: null }));
    }

    get size() {
        return this.entries.length;
    }

    // Round robin over the proxies that are not ejected and not in `exclude`
    // (a Set of entries, the ones a request already tried); null when none is left.
    pick(exclude = null) {
        const now = this.now();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[(this.next + i) % this.entries.length];
            if (e.ejectedUntil > now || exclude?.has(e)) continue;
            this.next = (this.next + i + 1) % this.entries.length;
            e.uses++;
            return e;
        }
        return null;
    }

    succeeded(entry) {
        entry.ok++;
        entry.consecutiveFails = 0;
        entry.ejectedUntil = 0;
    }

    failed(entry, message) {
        entry.failed++;
        entry.consecutiveFails++;
        entry.lastError = message;
        if (entry.consecutiveFails >= this.maxFails) entry.ejectedUntil = this.now() + this.retryAfterMs;
    }

    stats() {
        const now = this.now();
        const proxies = this.entries.map(({ name, uses, ok, failed, consecutiveFails, ejectedUntil, lastError }) => ({
            proxy: name,
            state: ejectedUntil > now ? 'ejected' : 'active',
            ...(ejectedUntil > now ? { retryInMs: ejectedUntil - now } : {}),
            uses,
            ok,
            failed,
            consecutiveFails,
            lastError,
        }));
        return {
            size: this.entries.length,
            active: proxies.filter((p) => p.state === 'active').length,
            maxFails: this.maxFails,
            retryAfterMs: this.retryAfterMs,
            proxies,
        };
    }
}

// Proxy URLs from a string: separated by commas, whitespace or newlines;
// a `#` starts a comment that runs to the end of the line.
export function parseProxyList(text) {
    return text
        .split('\n')
        .map((line) => line.replace(/#.*/, ''))
        .flatMap((line) => line.split(/[\s,]+/))
        .filter(Boolean);
}


// "host:port", or a URL whose host and port (default 443/80) are taken.
export function parseHostPort(raw) {
    const s = String(raw).trim();
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) {
        const u = new URL(s);
        return { host: u.hostname.replace(/^\[|\]$/g, ''), port: Number(u.port) || (u.protocol === 'https:' ? 443 : 80) };
    }
    const m = /^\[?([^\]]+?)\]?:(\d+)$/.exec(s);
    if (!m || !(Number(m[2]) > 0 && Number(m[2]) < 65536)) throw new Error(`expected host:port or a URL, got ${s}`);
    return { host: m[1], port: Number(m[2]) };
}

// Asks the proxy, directly, to open a tunnel to host:port (HTTP CONNECT, or a
// SOCKS5 CONNECT), with the credentials in its URL, and closes it again.
// Resolves to:
//   'unreachable'  no connection to the proxy (refused, unresolvable, TLS to
//                  it failed, or nothing within the time)
//   'auth'         the proxy rejected the credentials, or wanted some
//   'ok'           the tunnel was opened
//   'refused'      the proxy answered and would not open it (HTTP non-2xx,
//                  SOCKS reply other than success)
//   'silent'       connected, but no answer within the time or closed without one
export function askProxy(proxyUrl, { host, port }, timeoutMs = 2000) {
    let u;
    try {
        u = new URL(proxyUrl);
    } catch {
        return Promise.resolve('unreachable');
    }
    const user = decodeURIComponent(u.username);
    const pass = decodeURIComponent(u.password);
    return new Promise((resolve) => {
        let done = false, connected = false;
        const finish = (v) => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            sock.destroy();
            resolve(v);
        };
        const opts = { host: u.hostname.replace(/^\[|\]$/g, ''), port: Number(u.port) };
        const sock = u.protocol === 'https:' ? tls.connect({ ...opts, servername: opts.host, rejectUnauthorized: false }) : net.connect(opts);
        const timer = setTimeout(() => finish(connected ? 'silent' : 'unreachable'), Math.max(1, timeoutMs));
        sock.on('error', () => finish(connected ? 'silent' : 'unreachable'));
        sock.on('close', () => finish(connected ? 'silent' : 'unreachable'));
        let buf = Buffer.alloc(0);
        const authority = net.isIPv6(host) ? `[${host}]:${port}` : `${host}:${port}`;
        if (u.protocol === 'http:' || u.protocol === 'https:') {
            sock.on(u.protocol === 'https:' ? 'secureConnect' : 'connect', () => {
                connected = true;
                const cred = u.username ? `Proxy-Authorization: Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}\r\n` : '';
                sock.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n${cred}\r\n`);
            });
            sock.on('data', (c) => {
                buf = Buffer.concat([buf, c]);
                if (!buf.includes('\r\n')) return;
                const m = /^HTTP\/\d(?:\.\d)? (\d{3})\b/.exec(buf.toString('latin1').split('\r\n')[0]);
                if (!m) return finish('refused');
                const status = Number(m[1]);
                finish(status === 407 ? 'auth' : status >= 200 && status < 300 ? 'ok' : 'refused');
            });
        } else {
            // SOCKS5: greeting (username/password if the URL has them, else
            // none), RFC 1929 sub-negotiation, then CONNECT by name or address.
            let stage = 0;
            sock.on('connect', () => {
                connected = true;
                sock.write(Buffer.from([5, 1, u.username ? 2 : 0]));
            });
            const request = () => {
                const kind = net.isIP(host);
                const addr = kind === 4 ? Buffer.from([1, ...host.split('.').map(Number)])
                    : kind === 6 ? Buffer.concat([Buffer.from([4]), ipv6Bytes(host)])
                    : Buffer.concat([Buffer.from([3, Buffer.byteLength(host)]), Buffer.from(host)]);
                const p = Buffer.alloc(2);
                p.writeUInt16BE(port);
                sock.write(Buffer.concat([Buffer.from([5, 1, 0]), addr, p]));
                stage = 2;
            };
            sock.on('data', (c) => {
                buf = Buffer.concat([buf, c]);
                if (stage === 0 && buf.length >= 2) {
                    const method = buf[1];
                    buf = buf.subarray(2);
                    if (method === 0xff) return finish('auth');
                    if (method === 2) {
                        const ub = Buffer.from(user);
                        const pb = Buffer.from(pass);
                        sock.write(Buffer.concat([Buffer.from([1, ub.length]), ub, Buffer.from([pb.length]), pb]));
                        stage = 1;
                    } else if (method === 0) request();
                    else return finish('refused');
                }
                if (stage === 1 && buf.length >= 2) {
                    if (buf[1] !== 0) return finish('auth');
                    buf = buf.subarray(2);
                    request();
                }
                if (stage === 2 && buf.length >= 2) finish(buf[1] === 0 ? 'ok' : 'refused');
            });
        }
    });
}

function ipv6Bytes(addr) {
    const [head, tail = ''] = addr.split('::');
    const parts = (s) => (s ? s.split(':') : []);
    const h = parts(head), t = parts(tail);
    const words = [...h, ...Array(8 - h.length - t.length).fill('0'), ...t];
    return Buffer.from(words.flatMap((w) => [parseInt(w, 16) >> 8, parseInt(w, 16) & 0xff]));
}

// After a navigation through a proxy fails with a proxy-type error (see
// isProxyError), works out whose fault it was by asking the proxy directly
// for the same target, and — when the proxy is up but won't open that tunnel —
// for `probe`, a host:port it should always be able to reach. Resolves to:
//   'auth'         the proxy rejects the credentials (or wants some)
//   'proxy_down'   the proxy can't be reached, or can't reach the probe either
//   'target_down'  the proxy reaches the probe but not the target
//   'unknown'      the proxy is up and either no probe is configured, or it
//                  opens the target's tunnel now (a transient failure)
export async function diagnoseProxyFailure(proxyUrl, targetUrl, { probe = null, timeoutMs = 2000 } = {}) {
    const t0 = Date.now();
    const target = parseHostPort(targetUrl);
    const first = await askProxy(proxyUrl, target, timeoutMs);
    if (first === 'unreachable') return 'proxy_down';
    if (first === 'auth') return 'auth';
    if (first === 'ok' || !probe) return 'unknown';
    const left = timeoutMs - (Date.now() - t0);
    if (left <= 0) return 'unknown';
    const second = await askProxy(proxyUrl, probe, left);
    if (second === 'ok') return 'target_down';
    if (second === 'auth') return 'auth';
    return 'proxy_down';
}
