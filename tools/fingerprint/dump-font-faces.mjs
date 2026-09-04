#!/usr/bin/env node
// The names `local()` resolves against, measured off Chrome rather than
// derived from a family list.
//
//   node tools/fingerprint/dump-font-faces.mjs [--out src/browser/font_faces.zig]
//                                              [--port 9510] [--site-port 38861]
//
// `local()` does NOT look up a family. Measured on a headed Chrome 151,
// `local("Skia")` fails while `local("Skia Regular")` and `local("Skia-Regular")`
// succeed; the same holds for `PingFang HK`, `Times` and `Menlo`. What resolves
// is a face's full name or its PostScript name. Families whose regular face
// carries the family's own name -- Arial, Geneva, Luminari, InaiMathi -- match
// either way, which is why a family-keyed lookup passed for so long.
//
// That distinction is not academic: Cloudflare's challenge builds its font list
// out of `FontFace.load` (55 calls in one challenge, read off this engine's own
// prop_read log), so the lookup decides which families the guard is told about.
//
// The candidate list is every face name macOS reports for the families
// src/browser/font_metrics.zig already models, plus each family's own name and
// the constructed `<family> Regular` / `<family>-Regular` / ` Bold` / `-Bold` /
// ` Roman` / `-Roman` / no-space forms. Chrome is then asked about each one and
// only the ones it resolves are written out -- `system_profiler` misses the
// legacy Courier and Times .ttc faces that Chrome does resolve, so the browser
// has the last word rather than the OS.
//
// Chrome must be HEADED: which fonts a family resolves to is answered by the
// window system (see the note at the top of srcset.zig's sibling probes).
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
const outPath = path.resolve(REPO, arg('--out', 'src/browser/font_faces.zig'));
const PORT = Number(arg('--port', '9510'));
const SITE = Number(arg('--site-port', '38861'));
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// The families this engine models, read out of the metrics table so the two
// files cannot drift apart.
const metrics = await fs.readFile(path.join(REPO, 'src/browser/font_metrics.zig'), 'utf8');
const table = metrics.match(/pub fn find\(name: \[\]const u8\) \?Family \{\n    const table = \[_\]struct \{ \[\]const u8, Family \}\{([\s\S]*?)\n    \};/);
if (!table) throw new Error('could not find the family table in font_metrics.zig');
const families = [...table[1].matchAll(/\.\{ "([^"]+)",/g)].map((m) => m[1]);

// What macOS says each of those families is made of.
const profiler = spawn('system_profiler', ['SPFontsDataType', '-json'], { stdio: ['ignore', 'pipe', 'ignore'] });
let profilerOut = '';
profiler.stdout.on('data', (b) => { profilerOut += b; });
await new Promise((r) => profiler.on('exit', r));
const byFamily = new Map();
for (const file of JSON.parse(profilerOut).SPFontsDataType ?? []) {
    for (const face of file.typefaces ?? []) {
        if (!face.family) continue;
        const set = byFamily.get(face.family) ?? new Set();
        for (const key of ['fullname', '_name']) if (face[key]) set.add(face[key]);
        byFamily.set(face.family, set);
    }
}

const candidates = new Set();
for (const family of families) {
    for (const name of byFamily.get(family) ?? []) candidates.add(name);
    candidates.add(family);
    candidates.add(family.replaceAll(' ', ''));
    for (const suffix of [' Regular', '-Regular', ' Roman', '-Roman', ' Bold', '-Bold']) {
        candidates.add(family + suffix);
    }
}
const names = [...candidates].sort();
console.error(`${families.length} families, ${names.length} candidate names`);

// A page to run on: `about:blank` is an opaque origin and a poor place to ask a
// browser about anything (see run-expr.mjs's note).
const site = http.createServer((_, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end('<!DOCTYPE html><html><head><title>faces</title></head><body></body></html>');
}).listen(SITE);

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'font-faces-'));
const chrome = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check', ...personaScaleFlags(),
], { stdio: 'ignore' });

let loaded;
try {
    let cdp;
    for (let i = 0; i < 100; i++) {
        try { cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`); break; } catch { await sleep(200); }
    }
    if (!cdp) throw new Error('chrome never came up');
    const { sessionId } = await newPage(cdp);
    await goto(cdp, sessionId, `http://localhost:${SITE}/`, { settleMs: 500 });
    const value = await evaluate(cdp, sessionId, `(async () => {
            const NAMES = ${JSON.stringify(names)};
            const ok = [];
            for (let i = 0; i < NAMES.length; i += 64) {
                const found = await Promise.all(NAMES.slice(i, i + 64).map(async (n) => {
                    try {
                        await new FontFace('probe' + i + n.length, 'local("' + n.replaceAll('"', '\\\\"') + '")').load();
                        return n;
                    } catch (e) { return null; }
                }));
                for (const n of found) if (n) ok.push(n);
            }
            return JSON.stringify(ok);
        })()`, { awaitPromise: true });
    loaded = JSON.parse(value);
    await cdp.close?.();
} finally {
    chrome.kill('SIGKILL');
    site.close();
    await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
}

// Lowercased and sorted, because the lookup is case-insensitive and binary.
const keys = [...new Set(loaded.map((n) => n.toLowerCase()))].sort();
console.error(`${loaded.length} of ${names.length} resolved, ${keys.length} distinct keys`);

const header = `// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// GENERATED by tools/fingerprint/dump-font-faces.mjs — do not hand-edit.
//
// The names a \`local()\` source resolves against on the reference host's
// Chrome: a face's full name or its PostScript name, NOT a family name.
// \`local("Skia")\` fails there while \`local("Skia Regular")\` succeeds. See the
// tool's header for how the list was measured and why the browser rather than
// \`system_profiler\` has the last word.
//
// ${keys.length} names, lowercased and sorted: the lookup is case-insensitive
// (\`local("MENLO-REGULAR")\` resolves) but not whitespace-insensitive
// (\`local(" Arial")\` and \`local("Arial  Bold")\` do not).
const std = @import("std");

/// Whether \`local(name)\` names a face this engine claims to have installed.
pub fn has(name: []const u8) bool {
    if (name.len == 0 or name.len > longest) {
        return false;
    }
    var lowered: [longest]u8 = undefined;
    _ = std.ascii.lowerString(lowered[0..name.len], name);
    return std.sort.binarySearch([]const u8, &names, lowered[0..name.len], order) != null;
}

fn order(needle: []const u8, candidate: []const u8) std.math.Order {
    return std.mem.order(u8, needle, candidate);
}

const longest = blk: {
    var n: usize = 0;
    for (names) |name| n = @max(n, name.len);
    break :blk n;
};

const names = [_][]const u8{
`;

const body = keys.map((k) => `    ${JSON.stringify(k)},`).join('\n');
const footer = `
};

const testing = @import("../testing.zig");

test "font_faces: local() matches a face name, not a family name" {
    // Chrome 151's answer for each, measured with the tool that wrote this file.
    try testing.expectEqual(false, has("Skia"));
    try testing.expectEqual(true, has("Skia Regular"));
    try testing.expectEqual(true, has("Skia-Regular"));
    try testing.expectEqual(false, has("PingFang HK"));
    try testing.expectEqual(true, has("PingFang HK Light"));
    // A family whose regular face carries the family's own name matches either
    // way, which is what made the family-keyed lookup look right.
    try testing.expectEqual(true, has("Geneva"));
    try testing.expectEqual(true, has("InaiMathi"));
    try testing.expectEqual(false, has("NoSuchFamilyQZX"));
}

test "font_faces: the lookup is case-insensitive but not space-insensitive" {
    try testing.expectEqual(true, has("MENLO-REGULAR"));
    try testing.expectEqual(true, has("times roman"));
    try testing.expectEqual(false, has(" Arial"));
    try testing.expectEqual(false, has("Arial  Bold"));
    try testing.expectEqual(false, has(""));
}
`;

await fs.writeFile(outPath, header + body + footer);
console.error(`wrote ${outPath}`);
