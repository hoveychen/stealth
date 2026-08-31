// Regenerates src/browser/webapi/css/chrome_arity.zig from the real Chrome on
// this machine.
//
//   node tools/fingerprint/dump-css-arity.mjs [--headed]
//
// How *many* things a declaration may hold. Nothing else in this family of
// tables answers that: the value classes say what a component may be and
// `chrome_bounds` says what range it may sit in, and both are asked of one
// component at a time. So `margin-top: 1px 2px` passes every test there is --
// each half is a `<length>` `margin-top` takes -- and this engine stores it
// where Chrome throws the declaration away (probe-css17.js).
//
// Two questions, both measured as a *negative*, which is what makes them safe
// to act on. The engine reads this table as a licence to refuse, so a property
// wrongly listed here loses a style the page was written with -- the one kind
// of wrong these tables exist never to be. A property is therefore only listed
// when Chrome refused everything it was offered:
//
//   one_component  no two-component value was accepted at all, in either of
//                  the two ways a value carries one (`a b` and `a/b`). The
//                  moment one is accepted the property is dropped from the
//                  table and nothing about its arity is claimed again.
//   comma_lists    some comma-separated value was accepted. This one is a
//                  positive, and it is the permissive side: a property in the
//                  list is one whose commas are never counted against it.
//
// The offer has to be wide enough that a property with a real two-component
// grammar shows it, and the sweep is asymmetric because the two halves of such
// a value are not alike. One half is something the property visibly takes --
// the generic values below, or one of its own accepted identifiers, which is
// what reaches `background-position: left top` and `overflow-clip-margin: 1px
// content-box`. The other half is routinely not a value at all on its own:
// `align-items: first baseline` and `justify-content: safe center` hang off a
// modifier Chrome refuses alone. So the second half is drawn from *every*
// identifier there is, accepted or not.
//
// Both halves of the offer are a ceiling, and both of them were once too low.
// A property is listed only when Chrome refused everything it was shown, so an
// offer that never reaches a property's real two-component grammar reads
// exactly like Chrome refusing it, and the engine then throws away a
// declaration Chrome keeps -- the one kind of wrong this family of tables
// exists never to be. Measured: `scroll-marker-group: after links` was missing
// because `links` is a Blink keyword no mdn-data syntax mentions, and
// `clip-path: circle() padding-box`, `shape-outside: circle() border-box` and
// `border-shape: circle() circle()` were all missing because no generic value
// was a function call. `transform` was the same defect, noticed once and
// patched at the other end with a hand-written exemption in
// `CSSStyleDeclaration.tooManyComponents`.
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
const PORT = Number(process.env.PORT ?? 9479);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_arity.zig');
const PAGE = 'data:text/html,<!doctype html><title>arity</title><body>';

// Pinned so a regeneration is reproducible; bump deliberately. Same release
// dump-css-keywords.mjs measured its candidate pool from.
const MDN_DATA = '2.24.0';
const MDN_FILES = ['properties.json', 'syntaxes.json', 'types.json'];

// mdn-data describes the standard, so a keyword Chrome has and the standard
// does not was never offered to it -- and "never offered" is indistinguishable
// from "refused" in a table measured as a negative. Blink's own list of every
// CSS value keyword it has is the exact ceiling instead. Same file and same pin
// dump-css-keywords.mjs widened its pool with.
const BLINK_KEYWORDS_REF = '82774a71a48bef8a53c33ba2ad92406b4a909735';
const BLINK_KEYWORDS_URL =
    `https://raw.githubusercontent.com/chromium/chromium/${BLINK_KEYWORDS_REF}` +
    '/third_party/blink/renderer/core/css/css_value_keywords.json5';

// One value of every shape a component can be, so the pair sweep offers a
// property something of the kind it takes even before its keywords are known.
//
// The shapes are not decoration and the list is not free to be tasteful. A
// property whose second component is a shape missing from here is measured as
// one-component and then refuses a declaration Chrome keeps: `"abcd"` earns
// its place because an OpenType tag is *four* characters, so `"s"` alone left
// `font-feature-settings: "liga" 1` unreachable and the property in the table.
//
// Widening this list is safe with one exception, which is why `var()`, `env()`
// and `attr()` are not in it: a declaration holding one of those parses for
// every property there is -- Chrome keeps the text and substitutes later -- so
// offering one would empty the table rather than widen the pool, and every real
// refusal in it would be lost. Narrowing is never safe.
const GENERIC = ['1px', '10%', '2', '1000', '-1px', '0', '1em', '1fr', '1deg',
    '0.5s', 'red', '#00ff00', 'url(a)', 'calc(1px)', '"s"', '"abcd"', 'a',
    'auto', 'none',
    // The shapes the nineteen above never offered. A function call is the one
    // that mattered: without it `clip-path`, `shape-outside`, `border-shape`
    // and `transform` all read as one-component.
    '1x', '96dpi', '1Hz', '--a', 'linear-gradient(red,blue)', 'translate(1px)',
    'circle()', 'path("M 0 0")', '[a]', '2n+1', 'counter(a)', 'min(1px,2px)',
    'U+0-7F', 'image-set(url(a) 1x)', 'cubic-bezier(0,0,1,1)', 'steps(1)'];

// A property with hundreds of accepted identifiers is a colour or an enum, and
// neither has a two-component grammar hiding in the tail of its list. The cap
// keeps the anchor set from growing with the pool; the sample is spread across
// the sorted list rather than taken off the front, so it is not all `a`-words.
// Measured against the widened pool: raising it to 32 changes not one row, so
// the cap is not a ceiling the way the two pools above were.
const KEYWORD_CAP = 16;

const CHUNK = 4; // properties per Runtime.evaluate

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

// Every bare identifier in a value syntax plus every keyword name Blink has,
// the same pool dump-css-keywords.mjs measures against: type references and
// function names are stripped, since neither is a value a property takes on
// its own.
async function candidatePool() {
    const base = `https://unpkg.com/mdn-data@${MDN_DATA}/css/`;
    const docs = await Promise.all(MDN_FILES.map(async (f) => {
        const res = await fetch(base + f);
        if (!res.ok) throw new Error(`${base}${f}: HTTP ${res.status}`);
        return res.json();
    }));
    const pool = new Set();
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
// `-internal-` names are dropped: they are restricted to parser modes an author
// stylesheet never uses, so Chrome rejects every one of them here and they
// would only lengthen a cross product that is already large.
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
  const generic = ${JSON.stringify(GENERIC)};
  const cap = ${KEYWORD_CAP};
  const el = document.createElement('div');
  document.body.appendChild(el);
  const takes = (property, value) => {
    el.style.cssText = '';
    el.style.setProperty(property, value);
    return el.style.length > 0;
  };
  // Spread across the sorted list rather than the first \`cap\` of it.
  const sample = (list) => {
    if (list.length <= cap) return list;
    const step = list.length / cap;
    const out = [];
    for (let i = 0; i < cap; i++) out.push(list[Math.floor(i * step)]);
    return out;
  };
  const out = {};
  for (const p of props) {
    const keywords = sample(cands.filter((c) => takes(p, c)));
    // Anchors are the values this property is known to take. Partners are
    // every identifier there is, because half of a two-component value is
    // routinely not a value at all on its own: \`align-items: first baseline\`
    // and \`justify-content: safe center\` both hang off a modifier that is
    // refused alone, and pairing only accepted values would never offer one.
    // The anchors lead the partner list so the likely combinations are tried
    // before the long tail.
    const atoms = generic.concat(keywords);
    const known = new Set(atoms);
    const partners = atoms.concat(cands.filter((c) => !known.has(c)));
    // The first accepted pair settles the property, so a two-component
    // grammar costs a handful of tries and only a genuinely one-component
    // property pays for the whole cross product.
    let pair = null;
    let comma = null;
    for (const a of atoms) {
      for (const b of partners) {
        if (!pair) {
          if (takes(p, a + ' ' + b)) pair = a + ' ' + b;
          else if (takes(p, b + ' ' + a)) pair = b + ' ' + a;
          else if (takes(p, a + '/' + b)) pair = a + '/' + b;
          else if (takes(p, b + '/' + a)) pair = b + '/' + a;
        }
        if (!comma && takes(p, a + ',' + b)) comma = a + ',' + b;
        if (pair && comma) break;
      }
      if (pair && comma) break;
    }
    out[p] = { keywords: keywords.length, pair, comma };
  }
  return JSON.stringify(out);
})()`;

// The property universe: the computed longhands plus the shorthands and legacy
// spellings, the same list dump-css-keywords.mjs measures. A camelCase alias is
// dash-cased and kept only when Chrome answers to that spelling.
const LIST_PROBE = `(() => {
  const d = getComputedStyle(document.body);
  const computed = [];
  for (let i = 0; i < d.length; i++) computed.push(d[i]);
  const dashed = (k) => k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
  const seen = new Set(computed);
  const extra = [];
  for (const k of Object.keys(d)) {
    if (!isNaN(+k)) continue;
    for (const name of [dashed(k), '-' + dashed(k)]) {
      if (seen.has(name)) continue;
      seen.add(name);
      try { CSSStyleValue.parse(name, 'inherit'); extra.push(name); } catch (e) {}
    }
  }
  return JSON.stringify({ userAgent: navigator.userAgent, computed, extra });
})()`;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-arity-'));
const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check'];
if (!process.argv.includes('--headed')) args.push('--headless=new');
const proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(prof, 'chrome.log'));
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
    const properties = [...listed.computed, ...listed.extra];
    process.stderr.write(`properties: ${listed.computed.length} computed longhands + ` +
        `${listed.extra.length} shorthands/aliases\n`);

    const measured = {};
    for (let i = 0; i < properties.length; i += CHUNK) {
        const slice = properties.slice(i, i + CHUNK);
        Object.assign(measured, JSON.parse(await evaluate(cdp, sessionId, PROBE(slice, candidates))));
        process.stderr.write(`  measured ${Math.min(i + CHUNK, properties.length)}/${properties.length}\n`);
    }
    cdp.close();

    const one = properties.filter((p) => measured[p].pair === null).sort();
    const commas = properties.filter((p) => measured[p].comma !== null).sort();
    process.stderr.write(`one-component: ${one.length}, comma lists: ${commas.length}\n`);
    // A property that takes a comma list and no two-component item is the
    // combination the engine has to get right in two steps rather than one --
    // `transition-duration: 1s, 2s` is kept and `1s 2s` is not -- so it is
    // worth seeing the count rather than trusting it.
    const both = one.filter((p) => measured[p].comma !== null);
    process.stderr.write(`  of which take a comma list: ${both.length}\n`);

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-arity.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${listed.computed.length} computed longhands and ${listed.extra.length} shorthands/aliases probed. Each pair`,
        `// offered is one half the property visibly takes -- one of ${GENERIC.length} generic`,
        `// values, or one of up to ${KEYWORD_CAP} identifiers it accepts alone -- against a`,
        `// second half drawn from every one of the ${candidates.length} identifiers mdn-data`,
        `// ${MDN_DATA} and Blink's own css_value_keywords.json5 at`,
        `// ${BLINK_KEYWORDS_REF.slice(0, 10)} carry between them, since a modifier like the`,
        '// `first` of `first baseline` is refused on its own and no pool of',
        '// accepted values would reach it.',
        '//',
        '// How many things a declaration may hold. The value classes and',
        '// `chrome_bounds` are both asked one component at a time, so `margin-top:',
        '// 1px 2px` passes every test they have -- each half is a `<length>` that',
        '// property takes -- and Chrome throws the declaration away.',
        '//',
        '// Absence is not a claim. A property missing from `one_component` had a',
        '// two-component value accepted and its arity is not modelled beyond that;',
        '// a property missing from `comma_lists` was never seen to take a comma,',
        '// which is only a refusal when the property is also one-component.',
        '',
        'const std = @import("std");',
        '',
        '/// Takes no two-component value at all: every `a b` and every `a/b` the',
        '/// sweep offered was refused. A `/` counts as a component of its own, so',
        '/// `width: 1px / 2px` is three of them and refused for the same reason',
        '/// `width: 1px 2px` is.',
        'pub const one_component = std.StaticStringMap(void).initComptime(.{',
        ...one.map((p) => `    .{ ${zigString(p)}, {} },`),
        '});',
        '',
        '/// Takes a comma-separated list. The count above runs per item, so a',
        '/// property here holds as many items as it likes and each of them is',
        '/// judged alone -- `transition-duration: 1s, 2s` is kept where `1s 2s` is',
        '/// not. A property *not* here has never been seen to take a comma, and a',
        '/// one-component property that does not take one refuses `1px,2px`.',
        'pub const comma_lists = std.StaticStringMap(void).initComptime(.{',
        ...commas.map((p) => `    .{ ${zigString(p)}, {} },`),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
