// A fixed number of CDP connection slots to one `lightpanda serve`.
//
// Each request leases a whole slot: the engine allows one browser context per
// connection, so two requests never share one. When every slot is leased the
// request waits in a FIFO queue until one is handed back or its deadline
// passes. A slot whose connection died (engine restarted, websocket dropped)
// or was abandoned mid-request is reconnected lazily by the next lease.

import { CdpConnection, CdpError } from './cdp.mjs';

const RECONNECT_BACKOFF_MS = [100, 250, 500, 1000];

export class Pool {
    constructor({ cdpUrl, size, queueMax, connectTimeoutMs = 5000 }) {
        this.cdpUrl = cdpUrl;
        this.queueMax = queueMax;
        this.connectTimeoutMs = connectTimeoutMs;
        this.slots = Array.from({ length: size }, (_, id) => ({ id, conn: null, busy: false }));
        this.waiters = [];
        this.reconnects = 0;
    }

    stats() {
        return {
            size: this.slots.length,
            busy: this.slots.filter((s) => s.busy).length,
            connected: this.slots.filter((s) => s.conn && !s.conn.closed).length,
            queued: this.waiters.length,
            reconnects: this.reconnects,
        };
    }

    // Resolves to a slot with a live connection, or throws a CdpError with
    // code queue_full, timeout (still queued at the deadline) or
    // engine_unavailable (could not connect before the deadline).
    async acquire(deadline) {
        const slot = await this.lease(deadline);
        try {
            await this.ensureConnected(slot, deadline);
            return slot;
        } catch (e) {
            this.release(slot);
            throw e;
        }
    }

    lease(deadline) {
        const free = this.slots.find((s) => !s.busy);
        if (free) {
            free.busy = true;
            return Promise.resolve(free);
        }
        if (this.waiters.length >= this.queueMax) {
            return Promise.reject(new CdpError('queue_full', `all ${this.slots.length} slots busy and ${this.waiters.length} requests queued`));
        }
        return new Promise((resolve, reject) => {
            const waiter = { resolve, reject };
            waiter.timer = setTimeout(() => {
                this.waiters.splice(this.waiters.indexOf(waiter), 1);
                reject(new CdpError('timeout', 'timed out waiting for a free browser slot'));
            }, Math.max(1, deadline - Date.now()));
            this.waiters.push(waiter);
        });
    }

    async ensureConnected(slot, deadline) {
        if (slot.conn && !slot.conn.closed) return;
        if (slot.conn) this.reconnects++;
        slot.conn = null;
        let lastErr;
        for (let attempt = 0; ; attempt++) {
            const left = deadline - Date.now();
            if (left <= 0) break;
            try {
                slot.conn = await CdpConnection.connect(this.cdpUrl, Math.min(left, this.connectTimeoutMs));
                return;
            } catch (e) {
                lastErr = e;
            }
            const wait = RECONNECT_BACKOFF_MS[Math.min(attempt, RECONNECT_BACKOFF_MS.length - 1)];
            await new Promise((r) => setTimeout(r, Math.min(wait, Math.max(0, deadline - Date.now()))));
        }
        throw new CdpError('engine_unavailable', lastErr?.message ?? `could not reach the engine at ${this.cdpUrl}`);
    }

    // Drops the leased slot's connection and opens a new one, for a request
    // that goes on after leaving the browser in an unknown state.
    async reset(slot, deadline) {
        slot.conn?.close();
        await this.ensureConnected(slot, deadline);
    }

    // `discard` drops the connection, so the engine tears down that worker's
    // browser and the next lease starts from a fresh one. Used whenever the
    // request did not end cleanly and the browser's state is unknown.
    release(slot, { discard = false } = {}) {
        if (discard && slot.conn) {
            slot.conn.close();
        }
        const waiter = this.waiters.shift();
        if (waiter) {
            clearTimeout(waiter.timer);
            waiter.resolve(slot);
            return;
        }
        slot.busy = false;
    }

    close() {
        for (const w of this.waiters) {
            clearTimeout(w.timer);
            w.reject(new CdpError('engine_unavailable', 'service shutting down'));
        }
        this.waiters = [];
        for (const s of this.slots) s.conn?.close();
    }
}
