// Minimal zero-dependency CDP client (Node >= 22 global WebSocket).
// Used by the fingerprint collectors so the baseline does not depend on a
// puppeteer/playwright version matching lightpanda's partial CDP surface.

export class Cdp {
    constructor(url) {
        this.url = url;
        this.nextId = 1;
        this.pending = new Map();
        this.listeners = [];
    }

    static async connect(httpBase) {
        const res = await fetch(`${httpBase}/json/version`);
        const { webSocketDebuggerUrl } = await res.json();
        const cdp = new Cdp(webSocketDebuggerUrl);
        await cdp.open();
        return cdp;
    }

    open() {
        return new Promise((resolve, reject) => {
            this.ws = new WebSocket(this.url);
            this.ws.addEventListener('open', () => resolve());
            this.ws.addEventListener('error', (e) => reject(new Error(`ws error: ${e.message ?? e.type}`)));
            this.ws.addEventListener('message', (ev) => this.onMessage(ev.data));
        });
    }

    onMessage(raw) {
        let msg;
        try {
            msg = JSON.parse(raw);
        } catch {
            return;
        }
        if (msg.id !== undefined && this.pending.has(msg.id)) {
            const { resolve, reject } = this.pending.get(msg.id);
            this.pending.delete(msg.id);
            if (msg.error) reject(new Error(`${msg.error.code} ${msg.error.message}`));
            else resolve(msg.result);
            return;
        }
        for (const fn of this.listeners) fn(msg);
    }

    on(fn) {
        this.listeners.push(fn);
    }

    send(method, params, sessionId) {
        const id = this.nextId++;
        const payload = { id, method };
        if (params) payload.params = params;
        if (sessionId) payload.sessionId = sessionId;
        this.ws.send(JSON.stringify(payload));
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject });
            setTimeout(() => {
                if (this.pending.delete(id)) reject(new Error(`timeout: ${method}`));
            }, 30000);
        });
    }

    close() {
        try {
            this.ws.close();
        } catch {
            /* already gone */
        }
    }
}

// Open a page target and attach, returning its sessionId.
export async function newPage(cdp) {
    const { browserContextId } = await cdp.send('Target.createBrowserContext');
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    return { sessionId, targetId, browserContextId };
}

// Navigate and give the page a chance to run its scripts. lightpanda has no
// reliable networkIdle signal across all versions, so we poll readyState.
export async function goto(cdp, sessionId, url, { settleMs = 3000 } = {}) {
    await cdp.send('Page.navigate', { url }, sessionId);
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
        try {
            const r = await evaluate(cdp, sessionId, 'document.readyState');
            if (r === 'complete') break;
        } catch {
            /* context not ready yet */
        }
        await sleep(200);
    }
    await sleep(settleMs);
}

export async function evaluate(cdp, sessionId, expression, { awaitPromise = false } = {}) {
    const res = await cdp.send(
        'Runtime.evaluate',
        { expression, returnByValue: true, awaitPromise },
        sessionId,
    );
    if (res.exceptionDetails) {
        const d = res.exceptionDetails;
        throw new Error(`page exception: ${d.text} ${d.exception?.description ?? ''}`);
    }
    return res.result?.value;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
