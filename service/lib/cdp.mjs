// Minimal zero-dependency CDP client over Node's global WebSocket (Node >= 22).
//
// One instance is one websocket, and lightpanda gives every websocket its own
// worker thread and browser, which allows exactly one browser context at a
// time. The pool therefore treats a connection as a single-tenant slot.

export class CdpError extends Error {
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}

// A command that lands while the engine is tearing a stalled page off the
// stack is refused with this message before it runs, so it is safe to retry.
const TERMINATED = 'Page execution terminated';

export class CdpConnection {
    constructor(url) {
        this.url = url;
        this.nextId = 1;
        this.pending = new Map();
        this.listeners = new Set();
        this.closed = false;
        this.closeListeners = new Set();
    }

    static connect(url, timeoutMs) {
        const conn = new CdpConnection(url);
        return new Promise((resolve, reject) => {
            const ws = new WebSocket(url);
            conn.ws = ws;
            const timer = setTimeout(() => {
                conn.close();
                reject(new CdpError('engine_unavailable', `connect to ${url} timed out`));
            }, timeoutMs);
            ws.addEventListener('open', () => {
                clearTimeout(timer);
                resolve(conn);
            });
            ws.addEventListener('error', (e) => {
                clearTimeout(timer);
                const why = e.message || e.error?.message || e.error?.code || 'connection refused or dropped';
                conn.markClosed(`websocket error: ${why}`);
                reject(new CdpError('engine_unavailable', `connect to ${url} failed: ${why}`));
            });
            ws.addEventListener('close', () => conn.markClosed('websocket closed'));
            ws.addEventListener('message', (ev) => conn.onMessage(ev.data));
        });
    }

    onMessage(raw) {
        let msg;
        try {
            msg = JSON.parse(raw);
        } catch {
            return;
        }
        if (msg.id !== undefined) {
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            clearTimeout(p.timer);
            if (msg.error) p.reject(new CdpError('cdp_error', `${p.method}: ${msg.error.code} ${msg.error.message}`));
            else p.resolve(msg.result ?? {});
            return;
        }
        for (const fn of this.listeners) fn(msg);
    }

    // Returns an unsubscribe function.
    on(fn) {
        this.listeners.add(fn);
        return () => this.listeners.delete(fn);
    }

    onClose(fn) {
        this.closeListeners.add(fn);
        return () => this.closeListeners.delete(fn);
    }

    markClosed(reason) {
        if (this.closed) return;
        this.closed = true;
        for (const p of this.pending.values()) {
            clearTimeout(p.timer);
            p.reject(new CdpError('engine_disconnected', `${p.method}: ${reason}`));
        }
        this.pending.clear();
        for (const fn of this.closeListeners) fn(reason);
    }

    close() {
        this.markClosed('closed by client');
        try {
            this.ws?.close();
        } catch {}
    }

    async send(method, params, sessionId, timeoutMs) {
        for (let attempt = 0; ; attempt++) {
            try {
                return await this.sendOnce(method, params, sessionId, timeoutMs);
            } catch (e) {
                if (!(e.code === 'cdp_error' && e.message.includes(TERMINATED)) || attempt >= 3) throw e;
                await new Promise((r) => setTimeout(r, 300));
            }
        }
    }

    sendOnce(method, params = {}, sessionId, timeoutMs = 30000) {
        if (this.closed) return Promise.reject(new CdpError('engine_disconnected', `${method}: connection is closed`));
        const id = this.nextId++;
        const msg = { id, method, params };
        if (sessionId) msg.sessionId = sessionId;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new CdpError('timeout', `${method}: no reply within ${timeoutMs}ms`));
            }, Math.max(1, timeoutMs));
            this.pending.set(id, { resolve, reject, timer, method });
            this.ws.send(JSON.stringify(msg));
        });
    }
}
