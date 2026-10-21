// Proxies: validating a proxy URL, a rotating pool with temporary ejection of
// proxies that keep failing, and telling a proxy's failure apart from the
// target's.
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
// mean the proxy itself could not be used: unreachable, unresolvable, a SOCKS
// handshake failure, or a CONNECT the proxy refused. TLS errors are left out:
// they are the target's certificate as often as an https proxy's. Through an HTTP proxy an
// unreachable *target* comes back as the proxy's own 502 page for http URLs,
// but as a refused CONNECT (CouldntConnect) for https URLs, so a dead target
// behind a CONNECT is charged to the proxy too.
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

    // Round robin over the proxies that are not ejected; null when all are.
    pick() {
        const now = this.now();
        for (let i = 0; i < this.entries.length; i++) {
            const e = this.entries[(this.next + i) % this.entries.length];
            if (e.ejectedUntil > now) continue;
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

// After a CONNECT-style failure the engine only says CouldntConnect (or Proxy
// for SOCKS), which reads the same for a wrong password and a dead proxy. Ask
// the proxy directly whether it rejects these credentials. Resolves to true
// when it does, false otherwise (including when it can't be reached).
export function proxyRejectsCredentials(proxyUrl, timeoutMs = 2000) {
    let u;
    try {
        u = new URL(proxyUrl);
    } catch {
        return Promise.resolve(false);
    }
    if (!u.username) return Promise.resolve(false);
    const user = decodeURIComponent(u.username);
    const pass = decodeURIComponent(u.password);
    return new Promise((resolve) => {
        let done = false;
        const finish = (v) => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            sock.destroy();
            resolve(v);
        };
        const opts = { host: u.hostname, port: Number(u.port) };
        const sock = u.protocol === 'https:' ? tls.connect({ ...opts, servername: u.hostname, rejectUnauthorized: false }) : net.connect(opts);
        const timer = setTimeout(() => finish(false), timeoutMs);
        sock.on('error', () => finish(false));
        let buf = Buffer.alloc(0);
        if (u.protocol === 'http:' || u.protocol === 'https:') {
            sock.on(u.protocol === 'https:' ? 'secureConnect' : 'connect', () => {
                const cred = Buffer.from(`${user}:${pass}`).toString('base64');
                sock.write(`CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Basic ${cred}\r\n\r\n`);
            });
            sock.on('data', (c) => {
                buf = Buffer.concat([buf, c]);
                const line = buf.toString('latin1').split('\r\n')[0];
                if (buf.includes('\r\n')) finish(/^HTTP\/\d(\.\d)? 407\b/.test(line));
            });
        } else {
            // SOCKS5 greeting offering only username/password, then RFC 1929.
            let stage = 0;
            sock.on('connect', () => sock.write(Buffer.from([5, 1, 2])));
            sock.on('data', (c) => {
                buf = Buffer.concat([buf, c]);
                if (stage === 0 && buf.length >= 2) {
                    if (buf[1] !== 2) return finish(buf[1] === 0xff);
                    buf = buf.subarray(2);
                    stage = 1;
                    const ub = Buffer.from(user);
                    const pb = Buffer.from(pass);
                    sock.write(Buffer.concat([Buffer.from([1, ub.length]), ub, Buffer.from([pb.length]), pb]));
                }
                if (stage === 1 && buf.length >= 2) finish(buf[1] !== 0);
            });
        }
    });
}
