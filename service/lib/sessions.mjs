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
//
// A jar not used (loaded or saved) for `ttlMs` expires as a whole: sweep()
// drops it from memory and deletes its file, and a load that finds it past
// its TTL before the next sweep starts from an empty jar. On disk "last used"
// is the file's mtime, which loads touch too. delete() drops a jar at once.
// Either way, a crawl that loaded the jar before it was dropped does not
// bring it back when it finishes.
//
// Each jar in memory carries a version, a store-wide counter bumped by every
// save that changes it, so a holder that keeps a browser open (an MCP
// session) can tell with one comparison, and no engine call, whether anyone
// changed the jar since its last load or checkpoint (changedSince).

import fs from 'node:fs/promises';
import path from 'node:path';

export const SESSION_ID = /^[A-Za-z0-9._-]{1,128}$/;

export const key = (c) => `${c.name}\t${c.domain}\t${c.path}`;
export const same = (a, b) => a.value === b.value && a.expires === b.expires && a.httpOnly === b.httpOnly && a.secure === b.secure && a.sameSite === b.sameSite;

// The fields Network.setCookies takes back; getAllCookies adds size and
// session, and expires -1 for a session cookie.
export function storable(c) {
    const out = { name: c.name, value: c.value, domain: c.domain, path: c.path, httpOnly: !!c.httpOnly, secure: !!c.secure };
    if (typeof c.expires === 'number' && c.expires > 0) out.expires = c.expires;
    if (c.sameSite) out.sameSite = c.sameSite;
    return out;
}

const expired = (c, nowS) => typeof c.expires === 'number' && c.expires > 0 && c.expires <= nowS;

export class SessionStore {
    // dir: where jars are persisted; null keeps them in memory only.
    // ttlMs: idle time after which a jar expires; 0 never expires one.
    constructor({ dir = null, ttlMs = 0, now = Date.now } = {}) {
        this.dir = dir;
        this.ttlMs = ttlMs;
        this.now = now;
        this.jars = new Map(); // id -> { cookies: Map(key -> cookie), lastUsed }
        this.onDisk = new Set(); // ids with a file in dir
        this.epochs = new Map(); // id -> times it was dropped
        this.bases = new WeakMap(); // array load() returned -> epoch at the time
        this.versions = new WeakMap(); // array load()/checkpoint() returned -> the jar's version it is current at
        this.seq = 0;
        this.writes = new Map(); // id -> promise of the last write
        this.saves = 0;
        this.writeErrors = 0;
        this.expired = 0;
        this.deleted = 0;
        this.lastSweep = null;
    }

    async init() {
        if (!this.dir) return;
        await fs.mkdir(this.dir, { recursive: true });
        for (const name of await fs.readdir(this.dir)) if (name.endsWith('.json')) this.onDisk.add(name.slice(0, -5));
    }

    file(id) {
        return path.join(this.dir, `${id}.json`);
    }

    stale(lastUsed) {
        return this.ttlMs > 0 && this.now() - lastUsed >= this.ttlMs;
    }

    async jar(id) {
        let jar = this.jars.get(id);
        if (jar && this.stale(jar.lastUsed)) {
            await this.drop(id);
            this.expired++;
            jar = null;
        }
        if (jar) return jar;
        let cookies = [];
        let lastUsed = this.now();
        if (this.dir) {
            try {
                const [text, st] = await Promise.all([fs.readFile(this.file(id), 'utf8'), fs.stat(this.file(id))]);
                if (this.stale(st.mtimeMs)) {
                    await this.drop(id);
                    this.expired++;
                } else {
                    cookies = JSON.parse(text).cookies ?? [];
                }
            } catch (e) {
                if (e.code !== 'ENOENT') throw e;
            }
        }
        // Another load of the same id may have finished while this one read.
        jar = this.jars.get(id);
        if (jar) return jar;
        jar = { cookies: new Map(cookies.map((c) => [key(c), c])), lastUsed, version: ++this.seq };
        this.jars.set(id, jar);
        return jar;
    }

    touch(id, jar) {
        jar.lastUsed = this.now();
        if (this.dir && this.onDisk.has(id)) {
            const t = new Date(jar.lastUsed);
            fs.utimes(this.file(id), t, t).catch(() => {});
        }
    }

    // The cookies to put into a new browser context for this session.
    async load(id) {
        const nowS = this.now() / 1000;
        const jar = await this.jar(id);
        this.touch(id, jar);
        const base = [...jar.cookies.values()].filter((c) => !expired(c, nowS));
        this.bases.set(base, this.epochs.get(id) ?? 0);
        this.versions.set(base, jar.version);
        return base;
    }

    // Whether the jar changed since `base` (what load() or checkpoint()
    // returned) was current: false when it did not, and when the jar was
    // dropped since (nothing to take from it then).
    changedSince(id, base) {
        const jar = this.jars.get(id);
        if (!jar || (this.bases.get(base) ?? 0) !== (this.epochs.get(id) ?? 0)) return false;
        return this.versions.get(base) !== jar.version;
    }

    // base: what load() returned for this crawl; final: getAllCookies at its end.
    // A crawl whose jar was deleted or expired since it loaded saves nothing.
    // Resolves to the jar's version after the merge if nobody else had changed
    // the jar since `base`, else (or when nothing was saved) to null.
    async save(id, base, final) {
        if (this.bases.has(base) && this.bases.get(base) !== (this.epochs.get(id) ?? 0)) return null;
        const jar = await this.jar(id);
        const before = jar.version;
        let changed = false;
        const start = new Map(base.map((c) => [key(c), c]));
        const end = new Map(final.map((c) => [key(c), storable(c)]));
        for (const [k, c] of end) {
            const was = start.get(k);
            if (!was || !same(was, c)) {
                const cur = jar.cookies.get(k);
                if (!cur || !same(cur, c)) changed = true;
                jar.cookies.set(k, c);
            }
        }
        for (const [k, c] of start) {
            if (!end.has(k) && jar.cookies.has(k) && same(jar.cookies.get(k), c)) {
                jar.cookies.delete(k);
                changed = true;
            }
        }
        const nowS = this.now() / 1000;
        for (const [k, c] of jar.cookies) {
            if (expired(c, nowS)) {
                jar.cookies.delete(k);
                changed = true;
            }
        }
        if (changed) jar.version = ++this.seq;
        jar.lastUsed = this.now();
        this.saves++;
        const current = this.versions.get(base) === before ? jar.version : null;
        if (this.dir) await this.persist(id);
        return current;
    }

    // save() for a holder that writes back more than once (an MCP session
    // bound to this id): `final` is merged against `base`, and the cookies
    // it holds now are returned as the base of its next checkpoint. When
    // nothing changed since `base`, the jar is only touched.
    async checkpoint(id, base, final) {
        const epoch = this.bases.get(base) ?? (this.epochs.get(id) ?? 0);
        const next = final.map(storable);
        const now = new Map(next.map((c) => [key(c), c]));
        if (now.size === base.length && base.every((c) => now.has(key(c)) && same(now.get(key(c)), c))) {
            if (epoch === (this.epochs.get(id) ?? 0) && this.jars.has(id)) this.touch(id, this.jars.get(id));
            return base;
        }
        const version = await this.save(id, base, final);
        this.bases.set(next, epoch);
        // Not current if someone else changed the jar in between: then the
        // holder's next changedSince() says so.
        if (version != null) this.versions.set(next, version);
        return next;
    }

    // Writes are chained per session so an older snapshot never lands after a
    // newer one; each write takes the jar as it is when its turn comes, and a
    // jar dropped in the meantime is not written back.
    persist(id) {
        return this.chain(id, async () => {
            const jar = this.jars.get(id);
            if (!jar) return;
            const tmp = `${this.file(id)}.${process.pid}.tmp`;
            const body = JSON.stringify({ id, updatedAt: new Date(this.now()).toISOString(), cookies: [...jar.cookies.values()] });
            try {
                await fs.writeFile(tmp, body);
                await fs.rename(tmp, this.file(id));
                this.onDisk.add(id);
            } catch (e) {
                this.writeErrors++;
                throw e;
            }
        });
    }

    chain(id, fn) {
        const prev = this.writes.get(id) ?? Promise.resolve();
        const next = prev.then(fn);
        const settled = next.catch(() => {});
        this.writes.set(id, settled);
        settled.then(() => {
            if (this.writes.get(id) === settled) this.writes.delete(id);
        });
        return next;
    }

    // Forgets the jar in memory and on disk. Resolves to whether there was one.
    async drop(id) {
        const had = this.jars.delete(id) | this.onDisk.has(id);
        this.epochs.set(id, (this.epochs.get(id) ?? 0) + 1);
        if (!this.dir) return !!had;
        // After any write in flight, so it cannot land after the unlink.
        return this.chain(id, async () => {
            this.onDisk.delete(id);
            try {
                await fs.unlink(this.file(id));
                return true;
            } catch (e) {
                if (e.code === 'ENOENT') return !!had;
                throw e;
            }
        });
    }

    async delete(id) {
        const had = await this.drop(id);
        if (had) this.deleted++;
        return had;
    }

    // Drops every jar idle for ttlMs: those in memory by their last use, the
    // files of the others by their mtime. Also removes temporary files a
    // crashed write left behind.
    async sweep() {
        if (!this.ttlMs) return 0;
        let n = 0;
        for (const [id, jar] of [...this.jars]) {
            if (this.stale(jar.lastUsed) && !this.writes.has(id)) {
                await this.drop(id);
                n++;
            }
        }
        if (this.dir) {
            for (const name of await fs.readdir(this.dir)) {
                const id = name.endsWith('.json') ? name.slice(0, -5) : null;
                if (id && this.jars.has(id)) continue;
                if (!id && !name.endsWith('.tmp')) continue;
                let st;
                try {
                    st = await fs.stat(path.join(this.dir, name));
                } catch {
                    continue;
                }
                if (!this.stale(st.mtimeMs)) continue;
                if (id) {
                    await this.drop(id);
                    n++;
                } else {
                    await fs.unlink(path.join(this.dir, name)).catch(() => {});
                }
            }
        }
        this.expired += n;
        this.lastSweep = new Date(this.now()).toISOString();
        return n;
    }

    // The sessions there are, most recently used first, at most `limit`:
    // { id, lastUsed, expiresAt, cookies, domains, loaded }. Cookie values
    // are not part of it. Sessions only on disk are ordered by their file's
    // mtime, and only the `limit` listed have their file read.
    async list(limit = 200) {
        const rows = new Map();
        for (const [id, jar] of this.jars) rows.set(id, { id, lastUsed: jar.lastUsed, jar });
        if (this.dir) {
            for (const id of this.onDisk) {
                if (rows.has(id)) continue;
                try {
                    rows.set(id, { id, lastUsed: (await fs.stat(this.file(id))).mtimeMs });
                } catch {}
            }
        }
        const top = [...rows.values()].sort((a, b) => b.lastUsed - a.lastUsed).slice(0, limit);
        const out = [];
        for (const r of top) {
            let cookies = r.jar ? [...r.jar.cookies.values()] : null;
            if (!cookies) {
                try {
                    cookies = JSON.parse(await fs.readFile(this.file(r.id), 'utf8')).cookies ?? [];
                } catch {
                    continue;
                }
            }
            out.push({
                id: r.id,
                lastUsed: new Date(r.lastUsed).toISOString(),
                expiresAt: this.ttlMs ? new Date(r.lastUsed + this.ttlMs).toISOString() : null,
                cookies: cookies.length,
                domains: [...new Set(cookies.map((c) => c.domain.replace(/^\./, '')))].sort(),
                loaded: !!r.jar,
            });
        }
        return { total: rows.size, sessions: out };
    }

    stats() {
        const stored = this.dir ? new Set([...this.onDisk, ...this.jars.keys()]).size : this.jars.size;
        return {
            persisted: !!this.dir,
            dir: this.dir,
            ttlMs: this.ttlMs,
            stored,
            loaded: this.jars.size,
            saves: this.saves,
            writeErrors: this.writeErrors,
            expired: this.expired,
            deleted: this.deleted,
            lastSweep: this.lastSweep,
        };
    }
}
