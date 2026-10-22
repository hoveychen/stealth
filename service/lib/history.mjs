// Request history: one JSON line per POST /crawl, appended to a file per UTC
// day, kept for `retentionDays` days and queryable (GET /history).
//
// Writing never holds up a request: record() only queues the line, and the
// queue is appended in one write per file every `flushMs` (sooner when it gets
// long). A failed write is reported on stderr and counted; the request has
// long since been answered. If the disk stays unwritable the queue is capped
// and its oldest lines are dropped (counted as `dropped`).
//
// Files are named crawl-YYYY-MM-DD.<replica>.jsonl. Replicas that share one
// volume (compose's crawl-multi) each append to their own file; a query reads
// every replica's files of the days it covers, so any replica answers for all
// of them. The day is the UTC date of the line's `time`.

import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';

const DAY_MS = 24 * 3600 * 1000;
const FILE = /^crawl-(\d{4}-\d{2}-\d{2})\.(.+)\.jsonl$/;
const MAX_QUEUED = 100_000;
const FLUSH_LINES = 2000;

export const MAX_LIMIT = 1000;

const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

export class History {
    // dir: where the files go; null disables history. replica: this process's
    // part of the file name ([A-Za-z0-9._-]).
    constructor({ dir = null, retentionDays = 7, replica = 'local', flushMs = 1000, now = Date.now } = {}) {
        this.dir = dir;
        this.retentionDays = retentionDays;
        this.replica = String(replica).replace(/[^A-Za-z0-9._-]/g, '_') || 'local';
        this.flushMs = flushMs;
        this.now = now;
        this.queue = []; // [day, line]
        this.timer = null;
        this.writing = Promise.resolve();
        this.written = 0;
        this.writeErrors = 0;
        this.dropped = 0;
        this.removed = 0;
        this.lastError = null;
        this.lastSweep = null;
    }

    get enabled() {
        return !!this.dir;
    }

    async init() {
        if (this.dir) await fsp.mkdir(this.dir, { recursive: true });
    }

    file(day) {
        return path.join(this.dir, `crawl-${day}.${this.replica}.jsonl`);
    }

    // `line`: the entry already serialized, when the caller has it.
    record(entry, line = null) {
        if (!this.dir) return;
        this.queue.push([dayOf(Date.parse(entry.time) || this.now()), line ?? JSON.stringify(entry)]);
        if (this.queue.length > MAX_QUEUED) this.dropped += this.queue.splice(0, this.queue.length - MAX_QUEUED).length;
        if (this.queue.length >= FLUSH_LINES) this.flush();
        else if (!this.timer) {
            this.timer = setTimeout(() => this.flush(), this.flushMs);
            this.timer.unref();
        }
    }

    // Appends everything queued so far; resolves when it is on disk (or the
    // write failed). Writes run one at a time, in order.
    flush() {
        clearTimeout(this.timer);
        this.timer = null;
        if (!this.queue.length) return this.writing;
        const batch = this.queue;
        this.queue = [];
        this.writing = this.writing.then(() => this.write(batch));
        return this.writing;
    }

    async write(batch) {
        const byDay = new Map();
        for (const [day, line] of batch) {
            if (!byDay.has(day)) byDay.set(day, []);
            byDay.get(day).push(line);
        }
        for (const [day, lines] of byDay) {
            try {
                await fsp.appendFile(this.file(day), lines.join('\n') + '\n');
                this.written += lines.length;
            } catch (e) {
                this.writeErrors++;
                this.lastError = e.message;
                console.error(`history: could not append ${lines.length} line(s) to ${this.file(day)}: ${e.message}`);
            }
        }
    }

    close() {
        return this.flush();
    }

    // Deletes the files of days older than the last `retentionDays` (today
    // included), whichever replica wrote them. Resolves to how many went.
    async sweep() {
        if (!this.dir || !this.retentionDays) return 0;
        const oldestKept = dayOf(this.now() - (this.retentionDays - 1) * DAY_MS);
        let n = 0;
        for (const name of await fsp.readdir(this.dir)) {
            const m = FILE.exec(name);
            if (!m || m[1] >= oldestKept) continue;
            try {
                await fsp.unlink(path.join(this.dir, name));
                n++;
            } catch (e) {
                if (e.code !== 'ENOENT') console.error(`history: could not remove ${name}: ${e.message}`);
            }
        }
        this.removed += n;
        this.lastSweep = new Date(this.now()).toISOString();
        return n;
    }

    // The history files by day, newest day first: [{ day, files: [path] }].
    async days() {
        const byDay = new Map();
        for (const name of await fsp.readdir(this.dir)) {
            const m = FILE.exec(name);
            if (!m) continue;
            if (!byDay.has(m[1])) byDay.set(m[1], []);
            byDay.get(m[1]).push(path.join(this.dir, name));
        }
        return [...byDay].sort((a, b) => (a[0] < b[0] ? 1 : -1)).map(([day, files]) => ({ day, files }));
    }

    // filter: { url, status: [n], code: [s], session_id, kind, since, until
    // (ms), limit, days }. session_id also matches an MCP line's mcp_session;
    // kind is "crawl" (lines from before kind existed count as crawl) or "mcp". Newest first. Without `since`, only the last `days` days
    // (today included) are read. Days are read newest first and the read
    // stops at the first day that brings the matches up to `limit`.
    async query({ url, status, code, session_id, kind, since, until, limit = 100, days = 3 } = {}) {
        await this.flush();
        const from = since ?? dayStart(this.now() - (days - 1) * DAY_MS);
        const fromDay = dayOf(from);
        const toDay = until !== undefined ? dayOf(until) : '9999-12-31';
        const needle = url ? url.toLowerCase() : null;
        const match = (e) =>
            (!needle || (e.url ?? '').toLowerCase().includes(needle) || (e.finalUrl ?? '').toLowerCase().includes(needle)) &&
            (!status || status.includes(e.status)) &&
            (!code || code.includes(e.code ?? 'ok')) &&
            (!session_id || e.session_id === session_id || e.mcp_session === session_id) &&
            (!kind || (e.kind ?? 'crawl') === kind) &&
            (since === undefined || Date.parse(e.time) >= since) &&
            (until === undefined || Date.parse(e.time) <= until);
        let out = [];
        let files = 0, lines = 0, bad = 0;
        for (const { day, files: paths } of await this.days()) {
            if (day > toDay) continue;
            if (day < fromDay) break;
            for (const p of paths) {
                const r = await lastMatches(p, match, limit);
                files++;
                lines += r.lines;
                bad += r.bad;
                out.push(...r.matches);
            }
            if (out.length >= limit) break;
        }
        out.sort((a, b) => (a.time < b.time ? 1 : a.time > b.time ? -1 : 0));
        out = out.slice(0, limit);
        return { entries: out, scanned: { files, lines, unreadable: bad }, from: new Date(from).toISOString(), ...(until !== undefined ? { until: new Date(until).toISOString() } : {}) };
    }

    stats() {
        return {
            enabled: !!this.dir,
            dir: this.dir,
            replica: this.replica,
            retentionDays: this.retentionDays,
            written: this.written,
            queued: this.queue.length,
            writeErrors: this.writeErrors,
            dropped: this.dropped,
            lastError: this.lastError,
            removedFiles: this.removed,
            lastSweep: this.lastSweep,
        };
    }
}

const dayStart = (ms) => Date.parse(dayOf(ms));

// The last `limit` lines of a file that parse and match, oldest first. Lines
// are streamed, so a large file costs time but not memory. A line that does
// not parse (one still being appended, say) is skipped and counted.
async function lastMatches(file, match, limit) {
    const ring = new Array(limit);
    let n = 0, lines = 0, bad = 0;
    let stream;
    try {
        stream = fs.createReadStream(file, { encoding: 'utf8' });
        for await (const line of readline.createInterface({ input: stream, crlfDelay: Infinity })) {
            if (!line) continue;
            lines++;
            let e;
            try {
                e = JSON.parse(line);
            } catch {
                bad++;
                continue;
            }
            if (!match(e)) continue;
            ring[n++ % limit] = e;
        }
    } catch (e) {
        if (e.code !== 'ENOENT') throw e;
    } finally {
        stream?.destroy();
    }
    const matches = n <= limit ? ring.slice(0, n) : [...ring.slice(n % limit), ...ring.slice(0, n % limit)];
    return { matches, lines, bad };
}
