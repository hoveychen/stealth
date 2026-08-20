// Regenerates src/browser/webapi/css/chrome_keywords.zig from the real Chrome
// on this machine.
//
//   node tools/fingerprint/dump-css-keywords.mjs [--headed]
//
// `CSSStyleValue.parse(property, value)` runs Chrome's real per-property value
// parser, so a bare identifier is only accepted when that property actually
// takes it: `parse('width', 'auto')` answers a CSSKeywordValue where
// `parse('width', 'notalength')` throws. This engine had no per-property value
// grammar at all and turned any identifier into a CSSKeywordValue, which made
// it measurably more permissive than Chrome -- a detector reads that straight
// off (probe-css7.js, `styleValueParseBad`).
//
// There is no API that lists a property's keywords, so this asks Chrome one
// (property, identifier) pair at a time and keeps the pairs it accepts. Two
// halves:
//
//   candidates  every bare identifier appearing in any value syntax in
//               mdn-data, fetched at generation time and pinned below. It is
//               only a candidate list -- nothing from it reaches the table
//               without Chrome accepting it -- but it is also the ceiling on
//               what the table can contain, so a keyword Chrome takes and
//               mdn-data has never heard of would be missing here and this
//               engine would then be *stricter* than Chrome. Widening the pool
//               is always safe; narrowing it is not.
//   accepted    the cross product, measured. Chunked over properties so no
//               single Runtime.evaluate outstays cdp.mjs's timeout.
//
// The CSS-wide keywords are lifted out: they are accepted by every property, so
// storing them per property would be 474 copies of the same five names.
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ??
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9474);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_keywords.zig');

// Pinned so a regeneration is reproducible; bump deliberately.
const MDN_DATA = '2.24.0';
const MDN_FILES = ['properties.json', 'syntaxes.json', 'types.json'];

// Accepted by every property, so they are checked separately rather than
// stored 474 times. Verified against Chrome below.
const CSS_WIDE = ['inherit', 'initial', 'revert', 'revert-layer', 'unset'];

// Nonsense identifiers, to separate "this property has a keyword set" from
// "this property takes an arbitrary <custom-ident>". `font-family: MyOwnFont`,
// `animation-name: whatever` and `grid-area: my-line` are all valid CSS, so a
// keyword table would reject them and leave this engine *stricter* than Chrome
// -- worse than the permissiveness it is here to fix, because it breaks real
// pages. A property that accepts any of these accepts anything, and its
// measured "keywords" are just the candidate pool echoed back, so it is stored
// as accepts-any and its list is dropped.
const SENTINELS = ['zqxjkwvbn', 'notalength', 'lp-probe-sentinel-42'];

const PAGE = 'data:text/html,<!doctype html><title>keywords</title><body>';
const CHUNK = 40; // properties per Runtime.evaluate

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

// Every bare identifier in a value syntax. Type references (`<length>`) and
// function names (`fit-content(`) are stripped: neither is a keyword a property
// accepts on its own, and letting them through only adds candidates Chrome will
// reject anyway.
async function candidatePool() {
    const base = `https://unpkg.com/mdn-data@${MDN_DATA}/css/`;
    const docs = await Promise.all(MDN_FILES.map(async (f) => {
        const res = await fetch(base + f);
        if (!res.ok) throw new Error(`${base}${f}: HTTP ${res.status}`);
        return res.json();
    }));
    const pool = new Set([...CSS_WIDE, ...SENTINELS]);
    for (const doc of docs) {
        for (const entry of Object.values(doc)) {
            if (typeof entry?.syntax !== 'string') continue;
            const bare = entry.syntax
                .replace(/<[^>]*>/g, ' ')
                .replace(/[a-zA-Z-]+\s*\(/g, ' ');
            for (const m of bare.matchAll(/[a-zA-Z][a-zA-Z0-9-]*/g)) pool.add(m[0]);
        }
    }
    return [...pool].sort();
}

const PROBE = (properties, candidates) => `(() => {
  const props = ${JSON.stringify(properties)};
  const cands = ${JSON.stringify(candidates)};
  const out = {};
  for (const p of props) {
    const ok = [];
    for (const c of cands) {
      try { CSSStyleValue.parse(p, c); ok.push(c); } catch (e) {}
    }
    out[p] = ok;
  }
  return JSON.stringify(out);
})()`;

// The property universe: the computed longhands plus the shorthands and legacy
// spellings. Measured: `parse` validates those too (`parse('margin',
// 'notalength')` and `parse('-webkit-border-radius', 'notalength')` both throw),
// but it only answers to the dash-case name -- `parse('borderTopWidth', ...)` is
// "Invalid property name" -- so the camelCase alias list is dash-cased and then
// filtered to the names Chrome actually recognises.
const LIST_PROBE = `(() => {
  const d = getComputedStyle(document.body);
  const computed = [];
  for (let i = 0; i < d.length; i++) computed.push(d[i]);
  const dashed = (k) => k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
  const seen = new Set(computed);
  const extra = [];
  for (const k of Object.keys(d)) {
    if (!isNaN(+k)) continue;
    // The camelCase spelling drops the leading dash of a vendor prefix
    // (\`webkitBorderRadius\`), so try it back on as well and keep whichever
    // spelling Chrome answers to.
    for (const name of [dashed(k), '-' + dashed(k)]) {
      if (seen.has(name)) continue;
      seen.add(name);
      try { CSSStyleValue.parse(name, 'inherit'); extra.push(name); } catch (e) {}
    }
  }
  return JSON.stringify({ userAgent: navigator.userAgent, computed, extra });
})()`;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'csskw-'));
const proc = spawn(CHROME, [
    ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check',
], { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(os.tmpdir(), 'csskw-chrome.log'));
proc.stdout.pipe(log);
proc.stderr.pipe(log);

try {
    const candidates = await candidatePool();
    process.stderr.write(`candidate identifiers: ${candidates.length}\n`);

    await sleep(1600);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);

    const listed = JSON.parse(await evaluate(cdp, sessionId, LIST_PROBE));
    const { userAgent } = listed;
    const computed = [...listed.computed, ...listed.extra];
    process.stderr.write(`properties: ${listed.computed.length} computed longhands + ${listed.extra.length} shorthands/aliases\n`);

    const accepted = {};
    for (let i = 0; i < computed.length; i += CHUNK) {
        const slice = computed.slice(i, i + CHUNK);
        Object.assign(accepted, JSON.parse(await evaluate(cdp, sessionId, PROBE(slice, candidates))));
        process.stderr.write(`  measured ${Math.min(i + CHUNK, computed.length)}/${computed.length}\n`);
    }
    cdp.close();

    // The CSS-wide keywords are only liftable if every property really does take
    // every one of them. Check rather than assume.
    for (const p of computed) {
        const set = new Set(accepted[p]);
        const missing = CSS_WIDE.filter((k) => !set.has(k));
        if (missing.length) {
            throw new Error(`${p} rejects CSS-wide keyword(s) ${missing.join(', ')}; they cannot be lifted out of the per-property table`);
        }
    }

    const anyIdent = computed.filter((p) => {
        const set = new Set(accepted[p]);
        return SENTINELS.some((s) => set.has(s));
    });
    const anySet = new Set(anyIdent);

    // Properties with an empty keyword set stay in the table. Dropping them made
    // them indistinguishable from a name the table does not cover, and the two
    // answers are opposites: `opacity` takes no identifier at all, so every one
    // is a rejection, where an uncovered name has to stay permissive.
    const perProperty = computed
        .filter((p) => !anySet.has(p))
        .map((p) => [p, accepted[p].filter((k) => !CSS_WIDE.includes(k) && !SENTINELS.includes(k))]);
    const pairs = perProperty.reduce((n, [, ks]) => n + ks.length, 0);
    const noKeywords = perProperty.filter(([, ks]) => ks.length === 0).length;

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-keywords.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${listed.computed.length} computed longhands and ${listed.extra.length} shorthands/aliases probed`,
        `// against ${candidates.length} candidate`,
        `// identifiers (every bare identifier in any mdn-data ${MDN_DATA} value syntax):`,
        `// ${pairs} accepted (property, keyword) pairs over ${perProperty.length} properties, of`,
        `// which ${noKeywords} take no bare identifier at all beyond the CSS-wide ones (an`,
        '// empty list is a rejection, where a name missing from the table entirely has',
        `// to stay permissive); and ${anyIdent.length} properties that take an arbitrary`,
        '// identifier, so no list is kept for them.',
        '//',
        '// This is what `CSSStyleValue.parse(property, value)` accepts, which is',
        '// Chrome\'s real per-property value parser. Absence from this table is only',
        '// evidence that Chrome rejected the identifier when it was measured -- a',
        '// keyword Chrome takes but mdn-data does not list was never offered to it and',
        '// would read as rejected here, so regenerate against a newer mdn-data rather',
        '// than hand-adding a name.',
        '',
        'const std = @import("std");',
        '',
        '// Accepted by every property, so they are not repeated per property.',
        'pub const css_wide = [_][]const u8{',
        ...CSS_WIDE.map((k) => `    ${zigString(k)},`),
        '};',
        '',
        '// Every bare identifier each property accepts, beyond the CSS-wide ones.',
        '// Keyed on the lowercased dash-case name, which is the only spelling Chrome',
        '// answers to here.',
        'pub const keywords = std.StaticStringMap([]const []const u8).initComptime(.{',
        ...perProperty.map(([p, ks]) =>
            `    .{ ${zigString(p)}, &.{ ${ks.map(zigString).join(', ')} } },`),
        '});',
        '',
        '// Properties whose value may be an arbitrary <custom-ident> (a font family,',
        '// an animation name, a grid line name). Measured: each of these accepted a',
        '// nonsense identifier, so no identifier can be rejected for them.',
        'pub const any_identifier = std.StaticStringMap(void).initComptime(.{',
        ...anyIdent.map((p) => `    .{ ${zigString(p)}, {} },`),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
