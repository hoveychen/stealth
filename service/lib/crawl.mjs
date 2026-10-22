// One crawl = lease a slot, open a fresh browser context on its connection,
// navigate, collect the requested outputs, dispose the context, hand the slot
// back. Anything that leaves the browser in an unknown state (a timeout, a
// dropped connection, a failed dispose) discards the connection instead, so
// the next request on that slot starts from a new browser.

import { CdpError } from './cdp.mjs';
import { diagnoseProxyFailure, isProxyError, normalizeProxyUrl, redact } from './proxies.mjs';
import { SESSION_ID } from './sessions.mjs';

export const FORMATS = ['html', 'markdown', 'eval', 'meta'];
export const WAIT_UNTIL = { load: 'load', domcontentloaded: 'DOMContentLoaded', networkidle: 'networkIdle' };

export class RequestError extends Error {}

// Validates a POST /crawl body; throws RequestError with a message for 400.
// `proxyPool` is the configured pool (or null); `proxyPoolDefault` says
// whether a request without a `proxy` field uses it.
export function normalizeRequest(body, { defaultTimeoutMs, maxTimeoutMs, proxyPool = null, proxyPoolDefault = false }) {
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new RequestError('body must be a JSON object');
    const { url, js } = body;
    if (typeof url !== 'string') throw new RequestError('url is required');
    let parsed;
    try {
        parsed = new URL(url);
    } catch {
        throw new RequestError(`url is not a valid URL: ${url}`);
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw new RequestError('url must be http or https');

    if (js !== undefined && typeof js !== 'string') throw new RequestError('js must be a string');
    let formats = body.formats ?? (js !== undefined ? ['html', 'meta', 'eval'] : ['html', 'meta']);
    if (!Array.isArray(formats) || formats.some((f) => !FORMATS.includes(f))) {
        throw new RequestError(`formats must be an array of ${FORMATS.join(', ')}`);
    }
    formats = [...new Set(formats)];
    if (js !== undefined && !formats.includes('eval')) formats.push('eval');
    if (formats.includes('eval') && js === undefined) throw new RequestError('format eval needs js');

    const timeout = body.timeout ?? defaultTimeoutMs;
    if (typeof timeout !== 'number' || !(timeout > 0)) throw new RequestError('timeout must be a positive number of milliseconds');
    if (timeout > maxTimeoutMs) throw new RequestError(`timeout must be at most ${maxTimeoutMs}`);

    const waitUntil = body.waitUntil ?? 'load';
    if (!(waitUntil in WAIT_UNTIL)) throw new RequestError(`waitUntil must be one of ${Object.keys(WAIT_UNTIL).join(', ')}`);

    let proxy;
    if (body.proxy === undefined) proxy = { mode: proxyPool && proxyPoolDefault ? 'pool' : 'direct' };
    else if (body.proxy === 'direct' || body.proxy === null) proxy = { mode: 'direct' };
    else if (body.proxy === 'pool') {
        if (!proxyPool) throw new RequestError('proxy "pool" needs a proxy pool (PROXY_POOL or PROXY_POOL_FILE), and none is configured');
        proxy = { mode: 'pool' };
    } else {
        try {
            proxy = { mode: 'url', url: normalizeProxyUrl(body.proxy) };
        } catch (e) {
            throw new RequestError(e.message);
        }
    }

    const sessionId = body.session_id;
    if (sessionId !== undefined && (typeof sessionId !== 'string' || !SESSION_ID.test(sessionId))) {
        throw new RequestError('session_id must be 1-128 characters of A-Z a-z 0-9 . _ -');
    }

    return { url: parsed.href, formats, js, timeout, waitUntil, proxy, sessionId };
}

// Parameters for Target.createBrowserContext. The engine applies proxyServer
// to this connection's HTTP client only, and restores it when the context is
// disposed.
function contextParams(proxyUrl) {
    return proxyUrl ? { proxyServer: proxyUrl } : {};
}

const HTML_EXPR = 'document.documentElement ? document.documentElement.outerHTML : ""';

// deps: { proxies: ProxyPool | null, sessions: SessionStore, partialGraceMs,
// proxyRetries, proxyProbe }. With `proxy: "pool"`, a crawl that fails
// because of its proxy is run again on the next pool proxy, up to
// `proxyRetries` more times and within the same deadline, on the same slot.
//
// `info` is filled in for the request history, whether the crawl succeeds or
// throws: queueMs, proxy (the last one used, password redacted, or null),
// proxiesTried (pool proxies), finalUrl and pageStatus (the main document's
// final URL and HTTP status, when it got that far).
export async function crawl(pool, req, { proxies, sessions, partialGraceMs, proxyRetries = 0, proxyProbe = null }, info = {}) {
    const t0 = Date.now();
    const deadline = t0 + req.timeout;
    const tried = new Set();
    const nextPoolProxy = () => {
        const e = proxies.pick(tried);
        if (e) tried.add(e);
        return e;
    };
    let poolProxy = null;
    if (req.proxy.mode === 'pool') {
        poolProxy = nextPoolProxy();
        if (!poolProxy) throw new CdpError('no_proxy_available', `all ${proxies.size} pool proxies are ejected after repeated failures; see GET /health`);
    }
    let proxyUrl = poolProxy?.url ?? (req.proxy.mode === 'url' ? req.proxy.url : null);
    info.proxy = proxyUrl && redact(proxyUrl);
    info.proxiesTried = tried.size;
    const startCookies = req.sessionId ? await sessions.load(req.sessionId) : null;
    // Filled in as the crawl goes: the CDP session id, the cookies to save
    // and, after a timeout, whatever snapshot could still be taken. One per
    // attempt; the cookies are the last ones any attempt read.
    let page, cookies = null;

    let slot, keep = false;
    try {
        slot = await pool.acquire(deadline);
        const queueMs = Date.now() - t0;
        info.queueMs = queueMs;
        for (let attempt = 1; ; attempt++) {
            page = { proxyUrl, startCookies, cookies: null, partial: null };
            keep = false;
            try {
                const out = await runInContext(slot.conn, req, page, deadline, partialGraceMs, (ok) => (keep = ok));
                cookies = page.cookies ?? cookies;
                if (out.meta) out.meta.timing = { queueMs, ...out.meta.timing, totalMs: Date.now() - t0 };
                if (poolProxy) proxies.succeeded(poolProxy);
                return out;
            } catch (e) {
                cookies = page.cookies ?? cookies;
                const { err, charge, retry } = await explainFailure(e, req, proxyUrl, deadline, proxyProbe);
                if (poolProxy && charge) proxies.failed(poolProxy, err.message);
                const next = poolProxy && retry && attempt <= proxyRetries && deadline > Date.now() ? nextPoolProxy() : null;
                if (!next) {
                    if (tried.size > 1) err.message += ` (tried ${tried.size} pool proxies)`;
                    throw err;
                }
                poolProxy = next;
                proxyUrl = next.url;
                info.proxy = redact(proxyUrl);
                info.proxiesTried = tried.size;
                if (!keep) await pool.reset(slot, deadline);
            }
        }
    } catch (e) {
        let err = e;
        if (err.code === 'timeout') {
            err = new CdpError('timeout', `request exceeded its ${req.timeout}ms timeout (${e.message})`);
            const partial = {};
            if (req.formats.includes('html')) partial.html = page?.partial?.html ?? null;
            if (req.formats.includes('markdown')) partial.markdown = page?.partial?.markdown ?? null;
            if (Object.keys(partial).length) err.partial = { ...partial, source: page?.partial?.source ?? null };
        }
        throw err;
    } finally {
        info.finalUrl = page?.finalUrl ?? null;
        info.pageStatus = page?.pageStatus ?? null;
        if (slot) pool.release(slot, { discard: !keep });
        if (req.sessionId && cookies) {
            await sessions.save(req.sessionId, startCookies, cookies).catch((e) => console.error(`session ${req.sessionId}: could not save cookies: ${e.message}`));
        }
    }
}

// What a failed attempt means. `charge`: count it against the pool proxy;
// `retry`: another pool proxy might do better. A proxy-type engine error is
// checked with the proxy itself (diagnoseProxyFailure): only a proxy that is
// down or rejects the credentials is charged; a target the proxy can't reach
// while it reaches the probe is the target's failure; and when that can't be
// told (no probe, or the tunnel opens fine when asked again) nothing is
// charged but the next proxy is still tried.
async function explainFailure(e, req, proxyUrl, deadline, probe) {
    if (e.code === 'proxy_auth_failed') return { err: e, charge: true, retry: true };
    if (!(e.code === 'navigation_failed' && proxyUrl && isProxyError(e.errorText))) return { err: e, charge: false, retry: false };
    const left = deadline - Date.now();
    const verdict = left > 0 ? await diagnoseProxyFailure(proxyUrl, req.url, { probe, timeoutMs: Math.min(2000, left) }) : 'unknown';
    const name = redact(proxyUrl);
    const host = new URL(req.url).host;
    switch (verdict) {
        case 'auth':
            return { err: new CdpError('proxy_auth_failed', `proxy ${name} rejected the credentials (${e.errorText})`), charge: true, retry: true };
        case 'proxy_down':
            return { err: new CdpError('proxy_failed', `proxy ${name} failed: ${e.errorText} (${req.url})`), charge: true, retry: true };
        case 'target_down': {
            const err = navigationFailed(req.url, `${e.errorText}; proxy ${name} is up and reaches the probe address but not ${host}`);
            return { err, charge: false, retry: false };
        }
        default:
            return { err: new CdpError('proxy_failed', `proxy ${name} failed: ${e.errorText} (${req.url}); the proxy answers, so ${host} may be down instead${probe ? '' : ' (set PROXY_PROBE to tell them apart)'}`), charge: false, retry: true };
    }
}

// `setReusable(true)` is called only once the context has been disposed
// cleanly, which is what makes the connection safe to hand to the next request.
async function runInContext(conn, req, page, deadline, graceMs, setReusable) {
    const left = () => {
        const ms = deadline - Date.now();
        if (ms <= 0) throw new CdpError('timeout', `request exceeded its ${req.timeout}ms timeout`);
        return ms;
    };
    const send = (method, params, sessionId) => conn.send(method, params, sessionId, left());

    const { browserContextId } = await send('Target.createBrowserContext', contextParams(page.proxyUrl));
    page.browserContextId = browserContextId;
    let result, failure;
    try {
        result = await navigateAndCollect(conn, req, page, send, left);
    } catch (e) {
        failure = e;
    }
    if (failure?.code === 'timeout') {
        await snapshotAfterTimeout(conn, req, page, graceMs);
    } else if (failure && failure.code !== 'engine_disconnected' && req.sessionId && page.sessionId) {
        // A failed navigation can still have set cookies (a redirect hop).
        try {
            page.cookies = (await conn.sendOnce('Network.getAllCookies', {}, page.sessionId, 1000)).cookies ?? null;
        } catch {}
    }
    // A timed-out or disconnected page may be wedged in script; don't wait on
    // it, drop the connection instead.
    if (!failure || !['timeout', 'engine_disconnected'].includes(failure.code)) {
        try {
            await conn.send('Target.disposeBrowserContext', { browserContextId }, undefined, Math.min(5000, Math.max(1000, deadline - Date.now())));
            setReusable(true);
        } catch {}
    }
    if (failure) throw failure;
    return result;
}

// After the deadline, give the page `graceMs` more to hand over what it has:
// the requested html/markdown, and the cookies when there is a session. The
// commands go out together, without retries, and whatever has not answered
// when the grace runs out is left null. A page stuck in script answers
// nothing; the connection is dropped afterwards either way.
//
// The engine hands the main document to the page only once its whole body is
// in, so while a body never finishes the page is still the previous
// about:blank. LP.getPartialBody, asked alongside, has the bytes that did
// arrive (and markdown made from them in a detached document; the page sees
// neither): when the DOM has nothing, those are what `partial` carries, marked
// `source: "raw-body"`.
async function snapshotAfterTimeout(conn, req, page, graceMs) {
    if (!page.sessionId || conn.closed || graceMs <= 0) return;
    const ask = (method, params, pick) =>
        conn.sendOnce(method, params, page.sessionId, graceMs).then(pick, () => null);
    const wantHtml = req.formats.includes('html');
    const wantMarkdown = req.formats.includes('markdown');
    const [html, markdown, raw, cookies] = await Promise.all([
        wantHtml ? ask('Runtime.evaluate', { expression: HTML_EXPR, returnByValue: true }, (r) => (r.exceptionDetails ? null : (r.result?.value ?? null))) : null,
        wantMarkdown ? ask('LP.getMarkdown', {}, (r) => r.markdown ?? null) : null,
        wantHtml || wantMarkdown ? ask('LP.getPartialBody', { markdown: wantMarkdown }, (r) => (r.available ? r : null)) : null,
        req.sessionId ? ask('Network.getAllCookies', {}, (r) => r.cookies ?? null) : null,
    ]);
    page.partial = raw && domIsEmpty(html, markdown)
        ? { html: wantHtml ? raw.body : null, markdown: raw.markdown ?? null, source: 'raw-body' }
        : { html, markdown, source: 'dom' };
    if (cookies) page.cookies = cookies;
}

// No text in either reading, as with about:blank (`""` or an empty
// <html><head></head><body></body></html>).
function domIsEmpty(html, markdown) {
    return !(html ?? '').replace(/<[^>]*>/g, '').trim() && !(markdown ?? '').trim();
}

async function navigateAndCollect(conn, req, page, send, left) {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank', browserContextId: page.browserContextId });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    page.sessionId = sessionId;

    const events = [];
    let wake = () => {};
    const unsubscribe = conn.on((m) => {
        if (m.sessionId !== sessionId) return;
        events.push(m);
        wake();
    });
    const unsubscribeClose = conn.onClose(() => wake());
    let loaderId;
    try {
        await send('Page.enable', {}, sessionId);
        await send('Network.enable', {}, sessionId);
        await send('Page.setLifecycleEventsEnabled', { enabled: true }, sessionId);
        if (page.startCookies?.length) await send('Network.setCookies', { cookies: page.startCookies.map(setCookieParam) }, sessionId);

        const tNav = Date.now();
        const nav = await send('Page.navigate', { url: req.url }, sessionId);
        if (nav.errorText) throw navigationFailed(req.url, nav.errorText);
        loaderId = nav.loaderId;
        const lifecycle = WAIT_UNTIL[req.waitUntil];

        // Wait for the lifecycle event of this navigation, or its failure.
        for (let seen = 0; ; ) {
            for (; seen < events.length; seen++) {
                const { method, params } = events[seen];
                if (method === 'Page.lifecycleEvent' && params.loaderId === loaderId && params.name === lifecycle) break;
                if (method === 'Network.loadingFailed' && params.requestId === loaderId) {
                    throw navigationFailed(req.url, params.errorText || 'loading failed');
                }
            }
            if (seen < events.length) break;
            if (conn.closed) throw new CdpError('engine_disconnected', 'engine connection dropped during navigation');
            const ms = left();
            await new Promise((resolve) => {
                const timer = setTimeout(resolve, ms);
                wake = () => {
                    clearTimeout(timer);
                    resolve();
                };
            });
        }
        const navigateMs = Date.now() - tNav;
        const doc = events.findLast((m) => m.method === 'Network.responseReceived' && m.params.requestId === loaderId)?.params.response;
        page.finalUrl = doc?.url ?? null;
        page.pageStatus = doc?.status ?? null;
        // Through a proxy, an http:// URL with missing or wrong credentials
        // loads the proxy's 407 page instead of the target.
        if (page.proxyUrl && doc?.status === 407) {
            throw new CdpError('proxy_auth_failed', `proxy ${redact(page.proxyUrl)} answered 407 Proxy Authentication Required`);
        }

        const evaluate = async (expression, awaitPromise = false) => {
            const r = await send('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, sessionId);
            if (r.exceptionDetails) {
                const ex = r.exceptionDetails.exception;
                return { error: ex?.description ?? ex?.value ?? r.exceptionDetails.text ?? 'evaluation threw' };
            }
            return { value: r.result?.value ?? null };
        };

        const out = {};
        // Script runs first so it can act on the page (click, scroll, expand)
        // before the HTML and markdown snapshots are taken.
        if (req.formats.includes('eval')) out.eval = await evaluate(req.js, true);
        if (req.formats.includes('html')) {
            out.html = (await evaluate(HTML_EXPR)).value ?? '';
        }
        if (req.formats.includes('markdown')) out.markdown = (await send('LP.getMarkdown', {}, sessionId)).markdown ?? '';
        let cookies;
        if (req.formats.includes('meta') || req.sessionId) {
            cookies = (await send('Network.getAllCookies', {}, sessionId)).cookies ?? [];
            page.cookies = cookies;
        }
        if (req.formats.includes('meta')) {
            const hops = events.filter((m) => m.method === 'Network.requestWillBeSent' && m.params.requestId === loaderId).map((m) => m.params.request.url);
            const loc = (await evaluate('({ url: location.href, title: document.title })')).value ?? {};
            if (loc.url) page.finalUrl = loc.url;
            out.meta = {
                url: loc.url ?? doc?.url ?? null,
                title: loc.title ?? null,
                status: doc?.status ?? null,
                statusText: doc?.statusText ?? null,
                headers: doc?.headers ?? {},
                redirects: hops.slice(0, -1),
                cookies,
                timing: { navigateMs },
            };
        }
        return out;
    } finally {
        unsubscribe();
        unsubscribeClose();
        // A crawl that timed out waiting for its lifecycle event may still
        // have had the document's response; the history wants its URL.
        if (page.finalUrl === undefined && loaderId) {
            const doc = events.findLast((m) => m.method === 'Network.responseReceived' && m.params.requestId === loaderId)?.params.response;
            page.finalUrl = doc?.url ?? null;
            page.pageStatus = doc?.status ?? null;
        }
    }
}

function navigationFailed(url, errorText) {
    const e = new CdpError('navigation_failed', `${url}: ${errorText}`);
    e.errorText = errorText;
    return e;
}

// A cookie as getAllCookies reported it, in the form setCookies recreates it
// exactly. A host-only cookie reads back with a bare domain ("example.com",
// no leading dot); passing that as `domain` would make it a domain cookie,
// which the site's own Set-Cookie (host-only) then no longer overwrites or
// deletes. Giving a `url` instead keeps it host-only.
function setCookieParam(c) {
    if (c.domain.startsWith('.')) return c;
    const { domain, ...rest } = c;
    return { ...rest, url: `${c.secure ? 'https' : 'http'}://${domain}${c.path}` };
}
