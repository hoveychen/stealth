// Ends the `lightpanda serve` that /crawl uses, when the service stops.
//
// entrypoint.sh runs the engine and its restart loop under setsid, in a
// process group of its own, and writes that group's id to a file: the
// SIGTERM that `docker stop` sends to the container's group (tini -g) then
// reaches only the service, which lets the crawls in flight finish before it
// ends the engine here. Without the file (the service run outside the
// image, against an engine of its own) there is nothing to stop.

import fs from 'node:fs';

// SIGTERM to the group; whatever of it still runs after timeoutMs gets
// SIGKILL. Resolves to null without a group, else { pgid, killed, ms }.
export async function stopEngineGroup(pgidFile, timeoutMs, { pollMs = 50 } = {}) {
    let pgid;
    try {
        pgid = Number(fs.readFileSync(pgidFile, 'utf8').trim());
    } catch {
        return null;
    }
    if (!Number.isInteger(pgid) || pgid <= 1) return null;
    const t0 = Date.now();
    if (!signalGroup(pgid, 'SIGTERM')) return { pgid, killed: false, ms: 0 };
    while (groupAlive(pgid) && Date.now() - t0 < timeoutMs) await new Promise((r) => setTimeout(r, pollMs));
    const killed = groupAlive(pgid);
    if (killed) signalGroup(pgid, 'SIGKILL');
    return { pgid, killed, ms: Date.now() - t0 };
}

function signalGroup(pgid, sig) {
    try {
        process.kill(-pgid, sig);
        return true;
    } catch {
        return false;
    }
}

// Whether a process of the group is still running. Zombies don't count: the
// loop's shell is this process's child (the entrypoint exec'd into Node), so
// once it is killed it stays a zombie until the service exits.
export function groupAlive(pgid) {
    let names;
    try {
        names = fs.readdirSync('/proc');
    } catch {
        return false;
    }
    for (const name of names) {
        if (!/^\d+$/.test(name)) continue;
        let stat;
        try {
            stat = fs.readFileSync(`/proc/${name}/stat`, 'utf8');
        } catch {
            continue;
        }
        // pid (comm) state ppid pgrp ...; comm may hold spaces and parens.
        const [state, , pgrp] = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
        if (Number(pgrp) === pgid && state !== 'Z' && state !== 'X') return true;
    }
    return false;
}
