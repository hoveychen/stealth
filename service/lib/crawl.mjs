// One crawl = lease a slot, open a fresh browser context on its connection,
// navigate, collect the requested outputs, dispose the context, hand the slot
// back. Anything that leaves the browser in an unknown state (a timeout, a
// dropped connection, a failed dispose) discards the connection instead, so
// the next request on that slot starts from a new browser.

import { CdpError } from './cdp.mjs';

export const FORMATS = ['html', 'markdown', 'eval', 'meta'];
export const WAIT_UNTIL = { load: 'load', domcontentloaded: 'DOMContentLoaded', networkidle: 'networkIdle' };

export class RequestError extends Error {}

// Validates a POST /crawl body; throws RequestError with a message for 400.
export function normalizeRequest(body, { defaultTimeoutMs, maxTimeoutMs }) {
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

    return { url: parsed.href, formats, js, timeout, waitUntil };
}

// Parameters for Target.createBrowserContext. Per-request options that live
// on the context (a proxy, for one) belong here.
function contextParams(_req) {
    return {};
}

export async function crawl(pool, req) {
    const t0 = Date.now();
    const deadline = t0 + req.timeout;
    const slot = await pool.acquire(deadline);
    const queueMs = Date.now() - t0;
    let keep = false;
    try {
        const out = await runInContext(slot.conn, req, deadline, (ok) => (keep = ok));
        if (out.meta) out.meta.timing = { queueMs, ...out.meta.timing, totalMs: Date.now() - t0 };
        return out;
    } catch (e) {
        if (e.code === 'timeout') throw new CdpError('timeout', `request exceeded its ${req.timeout}ms timeout (${e.message})`);
        throw e;
    } finally {
        pool.release(slot, { discard: !keep });
    }
}

// `setReusable(true)` is called only once the context has been disposed
// cleanly, which is what makes the connection safe to hand to the next request.
async function runInContext(conn, req, deadline, setReusable) {
    const left = () => {
        const ms = deadline - Date.now();
        if (ms <= 0) throw new CdpError('timeout', `request exceeded its ${req.timeout}ms timeout`);
        return ms;
    };
    const send = (method, params, sessionId) => conn.send(method, params, sessionId, left());

    const { browserContextId } = await send('Target.createBrowserContext', contextParams(req));
    let result, failure;
    try {
        result = await navigateAndCollect(conn, req, send, left, browserContextId);
    } catch (e) {
        failure = e;
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

async function navigateAndCollect(conn, req, send, left, browserContextId) {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank', browserContextId });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });

    const events = [];
    let wake = () => {};
    const unsubscribe = conn.on((m) => {
        if (m.sessionId !== sessionId) return;
        events.push(m);
        wake();
    });
    const unsubscribeClose = conn.onClose(() => wake());
    try {
        await send('Page.enable', {}, sessionId);
        await send('Network.enable', {}, sessionId);
        await send('Page.setLifecycleEventsEnabled', { enabled: true }, sessionId);

        const tNav = Date.now();
        const nav = await send('Page.navigate', { url: req.url }, sessionId);
        if (nav.errorText) throw new CdpError('navigation_failed', `${req.url}: ${nav.errorText}`);
        const { loaderId } = nav;
        const lifecycle = WAIT_UNTIL[req.waitUntil];

        // Wait for the lifecycle event of this navigation, or its failure.
        for (let seen = 0; ; ) {
            for (; seen < events.length; seen++) {
                const { method, params } = events[seen];
                if (method === 'Page.lifecycleEvent' && params.loaderId === loaderId && params.name === lifecycle) break;
                if (method === 'Network.loadingFailed' && params.requestId === loaderId) {
                    throw new CdpError('navigation_failed', `${req.url}: ${params.errorText || 'loading failed'}`);
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
            out.html = (await evaluate('document.documentElement ? document.documentElement.outerHTML : ""')).value ?? '';
        }
        if (req.formats.includes('markdown')) out.markdown = (await send('LP.getMarkdown', {}, sessionId)).markdown ?? '';
        if (req.formats.includes('meta')) {
            const doc = events.findLast((m) => m.method === 'Network.responseReceived' && m.params.requestId === loaderId)?.params.response;
            const hops = events.filter((m) => m.method === 'Network.requestWillBeSent' && m.params.requestId === loaderId).map((m) => m.params.request.url);
            const page = (await evaluate('({ url: location.href, title: document.title })')).value ?? {};
            const { cookies } = await send('Network.getAllCookies', {}, sessionId);
            out.meta = {
                url: page.url ?? doc?.url ?? null,
                title: page.title ?? null,
                status: doc?.status ?? null,
                statusText: doc?.statusText ?? null,
                headers: doc?.headers ?? {},
                redirects: hops.slice(0, -1),
                cookies: cookies ?? [],
                timing: { navigateMs },
            };
        }
        return out;
    } finally {
        unsubscribe();
        unsubscribeClose();
    }
}
