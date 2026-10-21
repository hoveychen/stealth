// Cookie jars that outlive a crawl, keyed by the request's session_id.
//
// A crawl loads the jar into its fresh browser context (Network.setCookies)
// and, before the context is disposed, reads the context's cookies back
// (Network.getAllCookies) and merges them into the jar. With a directory, each
// jar is also a JSON file there, so sessions survive a restart.
//
// Concurrent crawls on one session each start from the jar as it was when
// they started, and merge per cookie (name, domain, path) against that
// starting point: a cookie the crawl set or changed is written, a cookie it
// started with and no longer has is deleted, and a cookie it left alone is
// not touched — so a cookie another crawl changed in the meantime survives.
// When two crawls change the same cookie, the one that finishes last wins.

import fs from 'node:fs/promises';
import path from 'node:path';

export const SESSION_ID = /^[A-Za-z0-9._-]{1,128}$/;

const key = (c) => `${c.name}\t${c.domain}\t${c.path}`;
const same = (a, b) => a.value === b.value && a.expires === b.expires && a.httpOnly === b.httpOnly && a.secure === b.secure && a.sameSite === b.sameSite;

// The fields Network.setCookies takes back; getAllCookies adds size and
// session, and expires -1 for a session cookie.
function storable(c) {
    const out = { name: c.name, value: c.value, domain: c.domain, path: c.path, httpOnly: !!c.httpOnly, secure: !!c.secure };
    if (typeof c.expires === 'number' && c.expires > 0) out.expires = c.expires;
    if (c.sameSite) out.sameSite = c.sameSite;
    return out;
}

const expired = (c, nowS) => typeof c.expires === 'number' && c.expires > 0 && c.expires <= nowS;

export class SessionStore {
    // dir: where jars are persisted; null keeps them in memory only.
    constructor({ dir = null } = {}) {
        this.dir = dir;
        this.jars = new Map(); // id -> Map(key -> cookie)
        this.writes = new Map(); // id -> promise of the last write
        this.saves = 0;
        this.writeErrors = 0;
    }

    async init() {
        if (this.dir) await fs.mkdir(this.dir, { recursive: true });
    }

    file(id) {
        return path.join(this.dir, `${id}.json`);
    }

    async jar(id) {
        let jar = this.jars.get(id);
        if (jar) return jar;
        let cookies = [];
        if (this.dir) {
            try {
                cookies = JSON.parse(await fs.readFile(this.file(id), 'utf8')).cookies ?? [];
            } catch (e) {
                if (e.code !== 'ENOENT') throw e;
            }
        }
        // Another load of the same id may have finished while this one read.
        jar = this.jars.get(id);
        if (jar) return jar;
        jar = new Map(cookies.map((c) => [key(c), c]));
        this.jars.set(id, jar);
        return jar;
    }

    // The cookies to put into a new browser context for this session.
    async load(id) {
        const nowS = Date.now() / 1000;
        return [...(await this.jar(id)).values()].filter((c) => !expired(c, nowS));
    }

    // base: what load() returned for this crawl; final: getAllCookies at its end.
    async save(id, base, final) {
        const jar = await this.jar(id);
        const start = new Map(base.map((c) => [key(c), c]));
        const end = new Map(final.map((c) => [key(c), storable(c)]));
        for (const [k, c] of end) {
            const was = start.get(k);
            if (!was || !same(was, c)) jar.set(k, c);
        }
        for (const [k, c] of start) {
            if (!end.has(k) && jar.has(k) && same(jar.get(k), c)) jar.delete(k);
        }
        const nowS = Date.now() / 1000;
        for (const [k, c] of jar) if (expired(c, nowS)) jar.delete(k);
        this.saves++;
        if (this.dir) await this.persist(id);
    }

    // Writes are chained per session so an older snapshot never lands after a
    // newer one; each write takes the jar as it is when its turn comes.
    persist(id) {
        const prev = this.writes.get(id) ?? Promise.resolve();
        const next = prev.then(async () => {
            const tmp = `${this.file(id)}.${process.pid}.tmp`;
            const body = JSON.stringify({ id, updatedAt: new Date().toISOString(), cookies: [...this.jars.get(id).values()] });
            try {
                await fs.writeFile(tmp, body);
                await fs.rename(tmp, this.file(id));
            } catch (e) {
                this.writeErrors++;
                throw e;
            }
        });
        const settled = next.catch(() => {});
        this.writes.set(id, settled);
        settled.then(() => {
            if (this.writes.get(id) === settled) this.writes.delete(id);
        });
        return next;
    }

    stats() {
        return { persisted: !!this.dir, dir: this.dir, loaded: this.jars.size, saves: this.saves, writeErrors: this.writeErrors };
    }
}
