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

// The other half of the pool, and the reason there are two.
//
// mdn-data describes the standard, so a property Chrome has and the standard
// does not is simply absent from it -- and because the pool is built out of the
// syntaxes mdn-data carries, an identifier only that property takes is never
// offered to Chrome at all. An identifier that is never offered reads exactly
// like one Chrome rejected, and the table then makes this engine STRICTER than
// Chrome: the declaration is dropped on the floor.
//
// That is not hypothetical. `-webkit-font-smoothing: antialiased` is in
// Cloudflare's own widget stylesheet; mdn-data 2.24.0 has no
// `-webkit-font-smoothing` entry and the string `antialiased` appears in no
// syntax in it, so the keyword was never a candidate and the widget's rule came
// out of this engine 37 characters shorter than out of Chrome -- one whole
// declaration missing, on every page that uses the property.
//
// `css_value_keywords.json5` is Blink's own list of every CSS value keyword it
// has, which makes it the exact ceiling: a keyword Chrome accepts anywhere
// cannot be missing from the pool. Chrome still decides every (property,
// keyword) pair, so this only widens what gets offered.
const BLINK_KEYWORDS_REF = '82774a71a48bef8a53c33ba2ad92406b4a909735';
const BLINK_KEYWORDS_URL =
    `https://raw.githubusercontent.com/chromium/chromium/${BLINK_KEYWORDS_REF}` +
    '/third_party/blink/renderer/core/css/css_value_keywords.json5';

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
// zig fmt drops the inner spaces of an empty or one-element list, and the
// generated file has to come out of here already formatted -- `zig build`
// depends on the fmt step, so a file needing a pass afterwards fails the build.
const zigList = (names) => {
    if (names.length === 0) return '&.{}';
    if (names.length === 1) return `&.{${zigString(names[0])}}`;
    return `&.{ ${names.map(zigString).join(', ')} }`;
};

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
    for (const name of await blinkKeywords()) pool.add(name);
    return [...pool].sort();
}

// Blink's own keyword names. The file is json5 with `//` comments and entries
// that are bare string literals inside `data: [...]`, plus the occasional
// object with a `name` field, and some entries commented out -- so the comments
// come off first or a disabled keyword would be read as a live one.
//
// `-internal-` names are dropped: `CSSValueKeywordsWriter` restricts them to
// parser modes an author stylesheet never uses, so Chrome rejects every one of
// them here and they would only lengthen a cross product that is already
// 682 x 2000.
async function blinkKeywords() {
    const res = await fetch(BLINK_KEYWORDS_URL);
    if (!res.ok) throw new Error(`${BLINK_KEYWORDS_URL}: HTTP ${res.status}`);
    const text = (await res.text()).replace(/\/\/[^\n]*/g, '');
    const data = text.slice(text.indexOf('data:'));
    const names = new Set();
    for (const m of data.matchAll(/"([^"]+)"/g)) names.add(m[1]);
    for (const m of data.matchAll(/name\s*:\s*"([^"]+)"/g)) names.add(m[1]);
    return [...names].filter((n) => !n.startsWith('-internal-'));
}

const PROBE = (properties, candidates) => `(() => {
  const props = ${JSON.stringify(properties)};
  const cands = ${JSON.stringify(candidates)};
  const sentinels = ${JSON.stringify(SENTINELS)};
  const el = document.createElement('div');
  document.body.appendChild(el);
  // Acceptance says a property takes the keyword; it does not say how Chrome
  // spells it back, and the candidate pool is spelled the way the *spec* spells
  // it (\`currentColor\`, \`ButtonFace\`, \`crispEdges\`, \`A4\`). So the spelling is
  // read off a real declaration rather than taken from the candidate. Measured
  // rather than lowercased on the way out, so a keyword Chrome ever does answer
  // with a capital would keep it.
  const spelling = (prop, keyword) => {
    el.style.removeProperty(prop);
    el.style.setProperty(prop, keyword);
    const readback = el.style.getPropertyValue(prop);
    for (const m of readback.matchAll(/[a-zA-Z][a-zA-Z0-9_-]*/g)) {
      const before = m.index > 0 ? readback[m.index - 1] : ' ';
      const after = readback[m.index + m[0].length] || ' ';
      // A whole identifier: not the unit of a dimension, not a function name.
      if (/[a-zA-Z0-9_#-]/.test(before) || after === '(') continue;
      if (m[0].toLowerCase() === keyword.toLowerCase()) return m[0];
    }
    // A shorthand can answer without the keyword in it at all -- \`display:
    // flow\` answers \`block\`, \`flex: none\` answers \`0 0 auto\`, \`border: none\`
    // answers nothing at all -- so this property cannot say how the keyword is
    // spelled. Another one will: measured over all 14392 accepted pairs, no
    // keyword is spelled two ways, so the spelling belongs to the keyword and
    // not to the property it sits in.
    return null;
  };
  const accepted = {};
  const spellings = {};
  for (const p of props) {
    // A property taking an arbitrary <custom-ident> answers every identifier as
    // written, so it can say nothing about a keyword's spelling -- and it is the
    // *first* property to accept most of them (\`animation-name\` before
    // \`color-interpolation\`), so learning from it would freeze the candidate's
    // own capitals. Same sentinel test the table itself is built on.
    const anyIdent = sentinels.some((sentinel) => {
      try { CSSStyleValue.parse(p, sentinel); return true; } catch (e) { return false; }
    });
    const ok = [];
    for (const c of cands) {
      try { CSSStyleValue.parse(p, c); } catch (e) { continue; }
      ok.push(c);
      if (!anyIdent && spellings[c] === undefined) {
        const spelled = spelling(p, c);
        // A shorthand that answers without the keyword in it says nothing about
        // the spelling either; some other property will.
        if (spelled !== null) spellings[c] = spelled;
      }
    }
    accepted[p] = ok;
  }
  return JSON.stringify({ accepted, spellings });
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
    const spellings = {};
    for (let i = 0; i < computed.length; i += CHUNK) {
        const slice = computed.slice(i, i + CHUNK);
        const got = JSON.parse(await evaluate(cdp, sessionId, PROBE(slice, candidates)));
        Object.assign(accepted, got.accepted);
        for (const [candidate, spelled] of Object.entries(got.spellings)) {
            spellings[candidate] ??= spelled;
        }
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
        // Sorted here rather than relying on the candidate pool's order: the
        // spelling written out is Chrome's, and lowercasing a spec-spelled
        // candidate moves it (`ButtonFace` sorted before `aliceblue`,
        // `buttonface` does not).
        // The candidate is what Chrome accepted; the spelling is what it
        // answers with, and two candidates can spell one keyword (`Menu` and
        // `menu` are both in mdn-data's colour list), so the list is deduped.
        .map((p) => [p, [...new Set(accepted[p]
            .filter((k) => !CSS_WIDE.includes(k) && !SENTINELS.includes(k))
            .map((k) => spellings[k] ?? k))].sort()]);
    const pairs = perProperty.reduce((n, [, ks]) => n + ks.length, 0);
    const allKeywords = [...new Set(perProperty.flatMap(([, ks]) => ks))].sort();
    const noKeywords = perProperty.filter(([, ks]) => ks.length === 0).length;

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-keywords.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${listed.computed.length} computed longhands and ${listed.extra.length} shorthands/aliases probed`,
        `// against ${candidates.length} candidate`,
        `// identifiers (every bare identifier in any mdn-data ${MDN_DATA} value syntax,`,
        `// plus every keyword name in Blink's own css_value_keywords.json5 at`,
        `// ${BLINK_KEYWORDS_REF}):`,
        `// ${pairs} accepted (property, keyword) pairs over ${perProperty.length} properties, of`,
        `// which ${noKeywords} take no bare identifier at all beyond the CSS-wide ones (an`,
        '// empty list is a rejection, where a name missing from the table entirely has',
        `// to stay permissive); and ${anyIdent.length} properties that take an arbitrary`,
        '// identifier, so no list is kept for them.',
        '//',
        '// This is what `CSSStyleValue.parse(property, value)` accepts, which is',
        '// Chrome\'s real per-property value parser, spelled the way Chrome answers a',
        '// declaration rather than the way mdn-data offered it: the pool is spec-spelled',
        '// (`currentColor`, `ButtonFace`, `crispEdges`, `A4`) and every one of those 59',
        '// keywords comes back in lower case. Absence from this table is only',
        '// evidence that Chrome rejected the identifier when it was measured, so an',
        '// entry is never hand-added -- regenerate instead.',
        '//',
        '// The pool used to be mdn-data alone, which made the table stricter than',
        '// Chrome for every property the standard does not describe: mdn-data has no',
        '// `-webkit-font-smoothing`, so `antialiased` was in no syntax, was never',
        '// offered, and read as rejected. Blink\'s own keyword file is the second half',
        '// for exactly that reason -- it is the ceiling on what Chrome can accept, so a',
        '// missing keyword now means Chrome said no.',
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
            `    .{ ${zigString(p)}, ${zigList(ks)} },`),
        '});',
        '',
        '// Every keyword the table knows, once. Measured: a property taking an',
        '// arbitrary <custom-ident> still canonicalises an identifier it recognises',
        "// as a keyword -- parse('animation-name', 'ButtonFace') answers `buttonface`",
        '// where `MyAnim` keeps its case -- and every one of these folded on both of',
        "// the two such properties swept, with the same set both times. Blink's own",
        '// keyword-id set is wider than this pool, so an identifier missing here keeps',
        '// its case: under-normalising, which is the safe direction.',
        'pub const all_keywords = std.StaticStringMap(void).initComptime(.{',
        ...allKeywords.map((k) => `    .{ ${zigString(k)}, {} },`),
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
