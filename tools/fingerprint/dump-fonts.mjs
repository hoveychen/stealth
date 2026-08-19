// Measures every font family the reference host has, out of the real Chrome, and
// regenerates src/browser/font_metrics.zig from it.
//
//   node tools/fingerprint/dump-fonts.mjs --survey   # what resolves, and how many
//   node tools/fingerprint/dump-fonts.mjs [--headed] # measure + write the table
//
// Font enumeration is the one fingerprint surface that is pure arithmetic: a
// probe sets `font = '100px "Candidate", monospace'`, measures a string, and
// compares against `monospace` alone. Different width means the candidate
// resolved, which means it is installed. So "which fonts does this machine have"
// is answered entirely by which families we hold advance tables for, and the
// only way to answer it the way the claimed platform would is to measure that
// platform's whole collection.
//
// The candidate list comes from the host, not from a hardcoded probe list:
//   system_profiler -json SPFontsDataType  ->  every installed family.
// A family is kept only if Chrome resolves it to something other than the
// fallback face, which is the same test a fingerprinting script applies.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9463;
const headed = process.argv.includes('--headed');
const surveyOnly = process.argv.includes('--survey');
const outPath = path.join(repo, 'src/browser/font_metrics.zig');
const jsonPath = path.join(repo, 'tools/fingerprint/results/reference-chrome-fonts.json');

// The three CSS generic families come first and keep their generic names; the
// rest are real families, measured under the name a stylesheet would use.
const GENERICS = ['sans-serif', 'serif', 'monospace'];
const SWEPT_SIZES = 120;

// Names a stylesheet or a probe can resolve that are not installed *families*:
// the remaining CSS generics, the ui-* keywords, the two system-font aliases
// every framework ships, and the legacy PostScript-era names Chrome still maps.
// They go through the same filter as everything else -- one that resolves to the
// fallback face is dropped and stays absent -- so listing a name here is a
// question, not an assertion.
const EXTRA_NAMES = [
    'cursive',
    'fantasy',
    'system-ui',
    'ui-serif',
    'ui-sans-serif',
    'ui-monospace',
    'ui-rounded',
    '-apple-system',
    'BlinkMacSystemFont',
    'Times',
    'Courier',
    'Lucida Grande',
];

/// Every family installed on this host, as CSS would name it. The dot-prefixed
/// ones are Apple's internal faces (".SF NS", ".Helvetica Neue DeskInterface"):
/// a stylesheet cannot resolve them, and Chrome does not, so they are dropped.
async function installedFamilies() {
    const out = await new Promise((resolve, reject) => {
        const p = spawn('system_profiler', ['-json', 'SPFontsDataType'], { stdio: ['ignore', 'pipe', 'ignore'] });
        let buf = '';
        p.stdout.on('data', (d) => (buf += d));
        p.on('error', reject);
        p.on('close', () => resolve(buf));
    });
    const families = new Set();
    for (const file of JSON.parse(out).SPFontsDataType ?? []) {
        for (const face of file.typefaces ?? []) {
            if (face.family && !face.family.startsWith('.')) families.add(face.family);
        }
    }
    return [...families].sort();
}

// One family's whole table. Runs in the page so the 95 advances, their ink
// boxes and the 120-size sweep are one round trip rather than 335.
const measure = (family, quoted) => `(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  const advances = (font) => {
    ctx.font = font;
    const out = [];
    for (let c = 32; c < 127; c++) {
      const m = ctx.measureText(String.fromCharCode(c));
      out.push([m.width, m.actualBoundingBoxLeft, m.actualBoundingBoxRight, m.actualBoundingBoxAscent, m.actualBoundingBoxDescent]);
    }
    return out;
  };
  ctx.font = '100px ${quoted}';
  const resolved = ctx.font;
  const glyphs = advances('100px ${quoted}');
  // The resolution test a real probe applies. It has to run against all three
  // generic bases, because each one has a blind spot: a name that resolves to the
  // default serif ('Times' on macOS) measures identically to 'serif', and one
  // that resolves to the default monospace ('Menlo') measures identically to
  // 'monospace'. Installed means at least one base moves -- which is exactly what
  // fingerprintjs-shaped probes do, and why they use three bases.
  const probed = {
    monospace: advances('100px ${quoted}, monospace'),
    'sans-serif': advances('100px ${quoted}, sans-serif'),
    serif: advances('100px ${quoted}, serif'),
  };
  const ascents = [], descents = [];
  for (let size = 1; size <= ${SWEPT_SIZES}; size++) {
    ctx.font = size + 'px ${quoted}';
    const m = ctx.measureText('');
    ascents.push(m.fontBoundingBoxAscent);
    descents.push(m.fontBoundingBoxDescent);
  }
  return JSON.stringify({ family: ${JSON.stringify(family)}, resolved, glyphs, probed, ascents, descents });
})()`;

// A CSS family name needs quoting unless it is a keyword. Quoting a keyword
// turns it into a family name Chrome will not resolve, which would silently
// answer "absent" for every generic.
const KEYWORDS = new Set([...GENERICS, 'cursive', 'fantasy', 'system-ui', 'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', '-apple-system']);
const quote = (family) => (KEYWORDS.has(family) ? family : `\\"${family}\\"`);

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-fonts-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check'];
if (!headed) flags.push('--headless=new');
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
// No pipe we do not read -- see dump-graphics.mjs.
const proc = ENDPOINT ? null : spawn(CHROME, flags, { stdio: 'ignore' });

let tables = [];
try {
    for (let i = 0; i < 100; i++) {
        try {
            if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) break;
        } catch {}
        await sleep(100);
    }
    const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

    // Deduped: a name in EXTRA_NAMES that also turns up as an installed family
    // would otherwise be measured twice and land in the table twice, once as a
    // face and once as an alias of itself.
    const candidates = [...new Set([...GENERICS, ...EXTRA_NAMES, ...(await installedFamilies())])];
    process.stderr.write(`${candidates.length} candidate families\n`);
    for (const family of candidates) {
        const r = await cdp.send(
            'Runtime.evaluate',
            { expression: measure(family, quote(family)), returnByValue: true },
            sessionId,
        );
        if (r.exceptionDetails) {
            process.stderr.write(`  skip ${family}: ${r.exceptionDetails.text}\n`);
            continue;
        }
        tables.push(JSON.parse(r.result.value));
    }
    cdp.close();
} finally {
    if (proc) proc.kill('SIGKILL');
    await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
}

const serif = tables.find((t) => t.family === 'serif');
const mono = tables.find((t) => t.family === 'monospace');
if (!serif || !mono) throw new Error('serif/monospace never measured; refusing to write a table without them');
if (!tables.find((t) => t.family === 'sans-serif')) throw new Error('sans-serif never measured');
// A face is identified by everything a probe can read off it, not just the
// advances: two families can share a Latin subset and still report different
// fontBoundingBox sweeps, and that difference is measurable.
const key = (t) => JSON.stringify([t.glyphs, t.ascents, t.descents]);
// Installed iff listing the name ahead of a generic moves that generic's own
// measurement, for at least one of the three.
const sans = tables.find((t) => t.family === 'sans-serif');
//
// Widths only, not ink boxes. A font with no Latin coverage -- Arial Hebrew, and
// most of the CJK and Indic families -- makes Chrome fall back per glyph, so
// Latin text measures exactly as wide as the base while the reported ink box can
// still differ. A probe reads the width, so the width is the test: comparing ink
// boxes as well made the engine detect one font (Arial Hebrew) that the real
// Chrome does not, on the same 65-name list.
const widths = (glyphs) => JSON.stringify(glyphs.map((g) => g[0]));
const baseWidths = {
    monospace: widths(mono.glyphs),
    'sans-serif': widths(sans.glyphs),
    serif: widths(serif.glyphs),
};
const resolves = (t) =>
    Object.keys(baseWidths).some((base) => widths(t.probed[base]) !== baseWidths[base]);

// Chrome falls back *per glyph*, and this engine picks one family for the whole
// string, so a family that covers only part of the tabulated range cannot be
// reproduced -- measured, not assumed: '100px "Arial Hebrew"' answers serif's
// width for 'm' and its own for '$', and '"Arial Hebrew", monospace' answers
// monospace's 'm' and the same '$'. 58 of the 95 characters move with the base.
//
// A family whose measurement does not depend on what follows it in the list has
// full coverage, and is the only kind this model can serve: keeping a partial one
// makes the engine detect a font the real Chrome does not (that was Arial Hebrew,
// the single disagreement on the 65-name fingerprintjs list).
const fullCoverage = (t) => {
    const alone = widths(t.glyphs);
    return Object.keys(baseWidths).every((base) => widths(t.probed[base]) === alone);
};

// Two families that resolve to the same face are one reading to a probe, but
// both names have to answer, so the duplicates become aliases of the first.
const kept = [];
const aliases = [];
const unresolved = [];
const partial = [];
const byFace = new Map();
for (const t of tables) {
    if (GENERICS.includes(t.family)) {
        kept.push(t);
        byFace.set(key(t), t.family);
        continue;
    }
    if (!resolves(t)) {
        // Chrome did not resolve it: leave it unmeasured, so a probe reads it as
        // not installed -- which is what it is.
        unresolved.push(t.family);
        continue;
    }
    if (!fullCoverage(t)) {
        partial.push(t.family);
        continue;
    }
    const seen = byFace.get(key(t));
    if (seen) {
        aliases.push([t.family, seen]);
        continue;
    }
    byFace.set(key(t), t.family);
    kept.push(t);
}

process.stderr.write(
    `${tables.length} measured -> ${kept.length} distinct faces, ${aliases.length} aliases, ` +
        `${tables.length - kept.length - aliases.length} unresolved\n`,
);

if (surveyOnly) {
    await fs.writeFile(jsonPath, JSON.stringify({ kept: kept.map((t) => t.family), aliases, unresolved, partial }, null, 1));
    process.stderr.write(`wrote ${path.relative(repo, jsonPath)}\n`);
    process.exit(0);
}

// ---------------------------------------------------------------------------
// Emit the Zig.

const ident = (family) =>
    'glyphs_' +
    family
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '_')
        .replace(/^_|_$/g, '');
const num = (v) => {
    // Zig wants a decimal point on a float literal, and the values are exact
    // binary fractions -- JS prints them round-trippably, so no rounding here.
    const s = String(v);
    return s.includes('.') || s.includes('e') ? s : `${s}.0`;
};
const CHAR_NAMES = { 32: 'space' };
const label = (c) => CHAR_NAMES[c] ?? String.fromCharCode(c);

const parts = [];
parts.push(`// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// GENERATED by tools/fingerprint/dump-fonts.mjs — do not hand-edit.
//
// Measured from ${serif.userAgent ?? 'the reference host\'s Google Chrome'} on macOS,
// which is the platform src/claimed_platform.zig claims.
//
// ${kept.length} distinct faces and ${aliases.length} aliases, out of ${tables.length} names
// measured. ${unresolved.length} did not resolve at all, and ${partial.length} cover only part of
// U+0020..U+007E — Chrome falls back per glyph for those and this engine cannot,
// so keeping them would make it detect fonts the real Chrome does not. Both
// groups are deliberately absent: font enumeration is the comparison a probe makes between
// '"Candidate", monospace' and 'monospace', so a name with no table of its own
// measures identically to its base and reads as not installed — which is what it
// is. That makes this file the engine's font list, and its size the number a
// detector reports.
//
// Two facts from the measurement make one table enough per family:
//
//   * advances are exactly linear in font size ('m' is 8.330078125 at 10px
//     and 83.30078125 at 100px), so a 100px table scales;
//   * a string's width is the plain sum of its glyphs' advances, except
//     across a kerning pair. 'mmmmmmmmmmlli', 'Hello, world!' and
//     'Cwm fjordbank glyphs vext quiz' all sum exactly; 'AV' and 'To' do
//     not, and we do not model kerning, so those come out a little wide.
//
// fontBoundingBox is the exception: CoreText quantises it per size (16px
// sans-serif reports an ascent of 14 where scaling 100px's 92 would say 15),
// so it is stored as a swept table for 1..${SWEPT_SIZES}px and extrapolated above that.
//
// Only U+0020..U+007E is tabulated. Anything else falls back to the family's
// mean advance, which is a guess and marked as one at the call site.

const std = @import("std");

/// One glyph, at a 100px font size. \`left\` and \`right\` are the ink bearings
/// TextMetrics reports as actualBoundingBoxLeft / Right: positive \`left\`
/// means the ink starts to the *left* of the pen, matching the web API's sign.
pub const Glyph = struct {
    advance: f64,
    left: f64,
    right: f64,
    ascent: f64,
    descent: f64,
};

pub const first_codepoint = 32;
pub const last_codepoint = 126;
/// The size every table below is measured at.
pub const basis = 100.0;

/// The swept range of \`ascents_*\` / \`descents_*\`. Larger sizes scale from
/// the last entry, which is close but not exact — CoreText's quantisation is
/// not a ratio.
pub const swept_sizes = ${SWEPT_SIZES};

pub const Family = struct {
    glyphs: []const Glyph,
    ascents: []const f64,
    descents: []const f64,
};
`);

const names = new Map();
for (const t of kept) {
    let base = ident(t.family);
    let name = base;
    for (let n = 2; names.has(name); n++) name = `${base}_${n}`;
    names.set(name, t);
    parts.push(`
/// 100px ${t.family} — Chrome resolves it to \`${t.resolved}\`.
const ${name} = [_]Glyph{`);
    t.glyphs.forEach(([advance, left, right, ascent, descent], i) => {
        parts.push(
            // Stored verbatim: actualBoundingBoxLeft already arrives negative
            // when the ink starts right of the pen, and the table keeps the web
            // API's sign so text_measure does no conversion.
            `    .{ .advance = ${num(advance)}, .left = ${num(left)}, .right = ${num(right)}, ` +
                `.ascent = ${num(ascent)}, .descent = ${num(descent)} }, // ${label(i + 32)}`,
        );
    });
    parts.push('};');
    const rows = (vals) => {
        const out = [];
        for (let i = 0; i < vals.length; i += 10) out.push('    ' + vals.slice(i, i + 10).map(num).join(', ') + ',');
        return out.join('\n');
    };
    parts.push(`const ascents_${name.replace(/^glyphs_/, '')} = [_]f64{
${rows(t.ascents)}
};
const descents_${name.replace(/^glyphs_/, '')} = [_]f64{
${rows(t.descents)}
};`);
}

parts.push('');
for (const [name, t] of names) {
    const bare = name.replace(/^glyphs_/, '');
    parts.push(
        `pub const ${bare}: Family = .{ .glyphs = &${name}, .ascents = &ascents_${bare}, .descents = &descents_${bare} };`,
    );
}

parts.push(`
/// Chrome falls back to the standard font for a family it cannot resolve:
/// '100px NoSuchFamily12345' measures exactly like '100px serif'.
pub const fallback = serif;

/// Maps a CSS family name to one of the measured families, ASCII
/// case-insensitively. Null when we have no table for it, which the caller
/// resolves by moving on to the next name in the list.
pub fn find(name: []const u8) ?Family {
    const table = [_]struct { []const u8, Family }{`);
for (const [name, t] of names) {
    parts.push(`        .{ "${t.family}", ${name.replace(/^glyphs_/, '')} },`);
}
if (aliases.length) {
    parts.push('        // Names Chrome resolves to a face already listed above.');
    for (const [alias, target] of aliases) {
        const bare = [...names].find(([, t]) => t.family === target)?.[0].replace(/^glyphs_/, '');
        parts.push(`        .{ "${alias}", ${bare} },`);
    }
}
parts.push(`    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) {
            return entry[1];
        }
    }
    return null;
}

/// The table for the first name in a comma-separated CSS family list we have
/// measurements for, falling back the way Chrome does when none resolves.
///
/// This is the whole of font enumeration. A probe asks for \`"Some Font",
/// monospace\` and compares the result against \`monospace\` alone: skipping the
/// names we have no table for is what makes a font we do have measure
/// differently, and a font we do not measure identically to its base.
pub fn findInList(list: []const u8) Family {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const unquoted = if (name.len >= 2 and (name[0] == '"' or name[0] == '\\'') and name[name.len - 1] == name[0])
            name[1 .. name.len - 1]
        else
            name;
        if (find(unquoted)) |family| {
            return family;
        }
    }
    return fallback;
}

/// The glyph for a codepoint at the table's 100px basis. Outside the
/// tabulated ASCII range we have no measurement, so this returns null and the
/// caller charges the family's mean advance instead.
pub fn glyph(family: Family, codepoint: u21) ?Glyph {
    if (codepoint < first_codepoint or codepoint > last_codepoint) {
        return null;
    }
    return family.glyphs[codepoint - first_codepoint];
}

/// \`fontBoundingBoxAscent\` / \`Descent\` at a size, from the swept table where
/// there is one and scaled from its last entry above that.
pub fn boundingBox(family: Family, size: f64) struct { ascent: f64, descent: f64 } {
    const rounded = @round(size);
    if (rounded >= 1 and rounded <= @as(f64, @floatFromInt(family.ascents.len)) and rounded == size) {
        const index: usize = @intFromFloat(rounded - 1);
        return .{ .ascent = family.ascents[index], .descent = family.descents[index] };
    }
    const last: f64 = @floatFromInt(family.ascents.len);
    const scale = size / last;
    return .{
        .ascent = family.ascents[family.ascents.len - 1] * scale,
        .descent = family.descents[family.descents.len - 1] * scale,
    };
}`);

await fs.writeFile(outPath, parts.join('\n') + '\n');
await fs.writeFile(
    jsonPath,
    JSON.stringify(
        {
            note: 'Survey of what dump-fonts.mjs kept. The metrics themselves live in the generated Zig.',
            kept: kept.map((t) => ({ family: t.family, resolved: t.resolved })),
            aliases,
            unresolved,
            partial,
        },
        null,
        1,
    ),
);
process.stderr.write(`wrote ${path.relative(repo, outPath)} — ${kept.length} faces, ${aliases.length} aliases\n`);
process.exit(0);
