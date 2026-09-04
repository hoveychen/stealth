// Regenerates src/browser/webapi/css/chrome_value_case.zig from the real Chrome
// on this machine.
//
//   node tools/fingerprint/dump-css-value-case.mjs [--headed]
//
// probe-css13.js measured that Chrome rewrites the case of four things inside a
// declaration's value -- a keyword, a unit, a function name and a CSS-wide
// keyword -- and leaves everything else exactly as authored. The keywords are
// already covered by chrome_keywords.zig; this fills the other two.
//
// Neither can be guessed from the value's shape. A unit is *nearly* always
// lowercase and a function name *nearly* always all-lowercase, but the
// exceptions are the whole point: `Q`, `Hz` and `kHz` are spelled with capitals
// in the spec, and `TranslateX(` comes back as `translateX(`, so a blanket
// `toLowerCase()` would be a fresh tell rather than a fix. So each candidate is
// written to a real declaration in upper case and read back, and whatever
// spelling Chrome answers with is the canonical one.
//
// Three lists come out:
//
//   units      unit -> the spelling Chrome serialises it with. A unit no
//              property accepts (a frequency: Chrome has no <frequency>
//              property) cannot be measured this way and is simply absent, so
//              the engine leaves it as authored.
//   functions  function name -> Chrome's spelling.
//   verbatim   the functions Chrome does *not* re-case, because their value is
//              substituted later and kept as the author wrote it. Measured:
//              their presence anywhere in the value freezes the *whole* value,
//              units and all -- `width: CALC(1PX + VAR(--a))` reads back byte
//              for byte. That is why they are a separate list and not just an
//              absence.
//
// Like the keyword table, the candidate pool is the ceiling: a function Chrome
// knows and mdn-data has never heard of is never offered to it, so it is
// missing here and the engine leaves it as authored. Widening the pool is
// always safe; narrowing it is not.
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ??
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9476);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_value_case.zig');

// Pinned so a regeneration is reproducible; bump deliberately. Same version the
// keyword table was generated against.
const MDN_DATA = '2.24.0';
const MDN_FILES = ['properties.json', 'syntaxes.json', 'types.json'];
// mdn-data's own list of CSS functions, which the value syntaxes above do not
// cover: `matrix()` and `min()` are here but appear in no property's syntax
// verbatim.
const MDN_FUNCTIONS = 'functions.json';
// Functions mdn-data spells as a *type* rather than a call, so neither source
// above ever offers them. `<url>` is the whole list at 2.24.0, and it is one of
// the four re-cased shapes probe-css13.js measured, so it cannot be skipped.
const EXTRA_FUNCTIONS = ['url'];

// Every dimension unit in css-values-4 plus the container-query and viewport
// variants, spelled the way the spec spells them. Case is irrelevant here --
// each is offered to Chrome upper-cased -- but the pool is the ceiling.
const UNITS = [
    'px', 'cm', 'mm', 'Q', 'in', 'pt', 'pc',
    'em', 'rem', 'ex', 'rex', 'ch', 'rch', 'ic', 'ric', 'lh', 'rlh', 'cap', 'rcap',
    'vw', 'vh', 'vi', 'vb', 'vmin', 'vmax',
    'svw', 'svh', 'svi', 'svb', 'svmin', 'svmax',
    'lvw', 'lvh', 'lvi', 'lvb', 'lvmin', 'lvmax',
    'dvw', 'dvh', 'dvi', 'dvb', 'dvmin', 'dvmax',
    'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax',
    'deg', 'grad', 'rad', 'turn',
    's', 'ms', 'Hz', 'kHz',
    'dpi', 'dpcm', 'dppx', 'x',
    'fr',
];

// A property that takes each kind of dimension. `1<unit>` is written to every
// one of them and the first that reads the dimension back wins.
const UNIT_HOSTS = [
    ['width', (v) => v],
    ['rotate', (v) => v],
    ['transition-duration', (v) => v],
    ['grid-template-columns', (v) => v],
    ['background-image', (v) => `image-set(url(a) ${v})`],
];

// Properties and arguments to try a function call against. Only one pair has to
// parse for the function's spelling to be measurable, so this is a net, not a
// mapping: no per-function knowledge is encoded here.
const FN_HOSTS = [
    'transform', 'color', 'background-image', 'width', 'filter', 'clip-path',
    'content', 'offset-path', 'background-position', 'grid-template-columns',
    'shape-outside', 'translate', 'scale', 'rotate', 'mask-image', 'cursor',
    'font-feature-settings', 'font-variant-alternates', 'counter-reset',
    'animation-timeline', 'list-style-image', 'background-size', 'd',
    'stroke-dasharray', 'transition-timing-function', 'will-change', 'height',
    'clip', 'list-style-type', 'anchor-name', 'background',
];
const FN_ARGS = [
    '', '1', '1px', '1%', '1deg', '1s', '1fr', '1 2 3', '1,2,3', '1px,2px',
    '1px 1px', 'red', '#fff', 'red,blue', 'to right,red,blue', '0 0',
    'url(a)', 'circle', 'a', 'a b', '"a"', '--a', 'Data-X',
    'safe-area-inset-top', '30% 40%', '1px,red', 'x', '0.5,0.5,0.5,0.5',
    '1px,2px,3px', '1px 2px 3px', '1,2', '2,1fr', '1,0,0,1,0,0',
    '1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1', '1,2%,3%', 'srgb 1 0 0', 'a,"."',
    '"M 0 0"', '45deg,red,blue', 'in srgb,red,blue', 'from red r g b',
    '1px at 50% 50%', 'closest-side at 50% 50%', 'red 0%,blue 100%',
    '1,1,1,45deg', '0 0 1px 1px', '0px,0px,0px,0px', 'url(a),url(b)', '#a',
];

const PAGE = 'data:text/html,<!doctype html><title>value case</title><body>';
const keywordList = (names) =>
    [...new Set(names)].filter((k) => !CSS_WIDE.includes(k)).sort();
// zig fmt writes a one-element list without the inner spaces, and the generated
// file has to come out of here already formatted.
const zigList = (names) => names.length === 1
    ? `&.{${zigString(names[0])}}`
    : `&.{ ${names.map(zigString).join(', ')} }`;
const CSS_WIDE = ['inherit', 'initial', 'revert', 'revert-layer', 'unset'];
const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

// Every function name appearing in any mdn-data value syntax. The keyword
// generator throws these away for the opposite reason: a function name is never
// a bare keyword, and a bare keyword is never a function.
async function candidatePool() {
    const base = `https://unpkg.com/mdn-data@${MDN_DATA}/css/`;
    const docs = await Promise.all(MDN_FILES.map(async (f) => {
        const res = await fetch(base + f);
        if (!res.ok) throw new Error(`${base}${f}: HTTP ${res.status}`);
        return res.json();
    }));
    const pool = new Set(EXTRA_FUNCTIONS);
    for (const doc of docs) {
        for (const entry of Object.values(doc)) {
            if (typeof entry?.syntax !== 'string') continue;
            for (const m of entry.syntax.matchAll(/([a-zA-Z][a-zA-Z0-9-]*)\s*\(/g)) {
                pool.add(m[1]);
            }
        }
    }
    const listed = await fetch(base + MDN_FUNCTIONS);
    if (!listed.ok) throw new Error(`${base}${MDN_FUNCTIONS}: HTTP ${listed.status}`);
    for (const name of Object.keys(await listed.json())) {
        pool.add(name.replace(/\(\)$/, ''));
    }
    return [...pool].sort();
}

// Every bare identifier in any value syntax, the same pool the keyword
// generator draws from -- and the same ceiling caveat.
async function identifierPool() {
    const base = `https://unpkg.com/mdn-data@${MDN_DATA}/css/`;
    const pool = new Set();
    for (const file of MDN_FILES) {
        const res = await fetch(base + file);
        if (!res.ok) throw new Error(`${base}${file}: HTTP ${res.status}`);
        for (const entry of Object.values(await res.json())) {
            if (typeof entry?.syntax !== 'string') continue;
            const bare = entry.syntax
                .replace(/<[^>]*>/g, ' ')
                .replace(/[a-zA-Z-]+\s*\(/g, ' ');
            for (const m of bare.matchAll(/[a-zA-Z][a-zA-Z0-9-]*/g)) pool.add(m[0]);
        }
    }
    return [...pool].sort();
}

// The properties chrome_keywords.zig marks as taking an arbitrary
// <custom-ident>, read out of the table rather than re-measured: they are
// exactly the properties whose keyword list that table has to leave empty, so
// they are exactly the ones needing this one. Both tables come off the same
// Chrome, so regenerate that one first if it looks stale.
async function anyIdentifierProperties() {
    const source = await fs.readFile(
        path.join(repo, 'src/browser/webapi/css/chrome_keywords.zig'), 'utf8');
    const start = source.indexOf('pub const any_identifier');
    if (start < 0) throw new Error('chrome_keywords.zig has no any_identifier table');
    const end = source.indexOf('});', start);
    return [...source.slice(start, end).matchAll(/\.\{ "([^"]+)", \{\} \}/g)].map((m) => m[1]);
}

const PROBE = (units, functions, hosts, args, anyIdentProperties, identCandidates) => `(() => {
  const el = document.createElement('div');
  document.body.appendChild(el);
  const set = (prop, value) => {
    el.style.removeProperty(prop);
    el.style.setProperty(prop, value);
    return el.style.getPropertyValue(prop);
  };
  // The spelling Chrome answered with, for a token that reads
  // case-insensitively the same as the one written.
  const spelled = (readback, re, want) => {
    for (const m of readback.matchAll(re)) {
      if (m[1].toLowerCase() === want.toLowerCase()) return m[1];
    }
    return null;
  };

  const units = {};
  for (const unit of ${JSON.stringify(units)}) {
    const written = '1' + unit.toUpperCase();
    for (const [prop, wrap] of ${JSON.stringify(hosts)}) {
      const readback = set(prop, wrap.replace('%V%', written));
      if (!readback) continue;
      const got = spelled(readback, /[0-9](?:\\.[0-9]+)?([a-zA-Z]+)/g, unit);
      if (got) { units[unit] = { host: prop, spelling: got }; break; }
    }
  }

  const functions = {};
  for (const fn of ${JSON.stringify(functions)}) {
    const upper = fn.toUpperCase();
    let done = false;
    for (const prop of ${JSON.stringify(FN_HOSTS)}) {
      for (const arg of ${JSON.stringify(args)}) {
        const readback = set(prop, upper + '(' + arg + ')');
        if (!readback) continue;
        const got = spelled(readback, /([a-zA-Z][a-zA-Z0-9-]*)\\(/g, fn);
        if (!got) continue;
        functions[fn] = { host: prop, arg: arg, spelling: got };
        done = true;
        break;
      }
      if (done) break;
    }
  }

  // A function whose spelling came back as written does not get re-cased. Does
  // its presence freeze the rest of the value too?
  const verbatim = {};
  for (const [fn, hit] of Object.entries(functions)) {
    if (hit.spelling !== fn.toUpperCase()) continue;
    const written = 'CALC(1PX + ' + fn.toUpperCase() + '(' + hit.arg + '))';
    verbatim[fn] = { written: written, readback: set('width', written) };
  }

  // A property that accepts an arbitrary <custom-ident> still has keywords --
  // \`font-family\` takes \`MyOwnFont\` *and* \`sans-serif\` -- and the keyword table
  // cannot tell them apart, because acceptance is not the signal there: Chrome
  // accepts both. Re-casing is the signal. Whatever comes back in a different
  // case than it went in was a keyword.
  // A whole identifier, not one buried in a dimension (the \`s\` of \`0s\`) or a
  // function name (the \`ease\` of \`ease-in(\`).
  const identSpelled = (readback, want) => {
    for (const m of readback.matchAll(/[a-zA-Z][a-zA-Z0-9-]*/g)) {
      const before = m.index > 0 ? readback[m.index - 1] : ' ';
      const after = readback[m.index + m[0].length] || ' ';
      if (/[a-zA-Z0-9_#-]/.test(before) || after === '(') continue;
      if (m[0].toLowerCase() === want.toLowerCase()) return m[0];
    }
    return null;
  };
  const idents = {};
  for (const prop of ${JSON.stringify(anyIdentProperties)}) {
    const hits = [];
    for (const cand of ${JSON.stringify(identCandidates)}) {
      const readback = set(prop, cand.toUpperCase());
      if (!readback) continue;
      const got = identSpelled(readback, cand);
      if (got && got !== cand.toUpperCase()) hits.push(got);
    }
    if (hits.length) idents[prop] = hits;
  }

  return JSON.stringify({ userAgent: navigator.userAgent, units, functions, verbatim, idents });
})()`;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cssvc-'));
const proc = spawn(CHROME, [
    ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
], { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(os.tmpdir(), 'cssvc-chrome.log'));
proc.stdout.pipe(log);
proc.stderr.pipe(log);

try {
    const candidates = await candidatePool();
    const identCandidates = await identifierPool();
    const anyIdent = await anyIdentifierProperties();
    process.stderr.write(`candidate functions: ${candidates.length}\n`);
    process.stderr.write(`any-identifier properties: ${anyIdent.length}` +
        ` against ${identCandidates.length} candidate identifiers\n`);

    await sleep(1600);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);

    const hosts = UNIT_HOSTS.map(([prop, wrap]) => [prop, wrap('%V%')]);
    const measured = JSON.parse(await evaluate(cdp, sessionId,
        PROBE(UNITS, candidates, hosts, FN_ARGS, anyIdent, identCandidates)));
    cdp.close();

    const { userAgent, units, functions, verbatim, idents } = measured;

    // A function Chrome echoed back in the case it was written in is one it does
    // not re-case at all; the measurement above says whether the rest of the
    // value freezes with it.
    const preserving = Object.keys(functions)
        .filter((fn) => functions[fn].spelling === fn.toUpperCase());
    const frozen = preserving.filter((fn) => {
        const v = verbatim[fn];
        return v && v.readback === v.written;
    });
    const partial = preserving.filter((fn) => !frozen.includes(fn));
    if (partial.length) {
        process.stderr.write(`WARNING: case-preserving but value not frozen: ${partial.join(', ')}\n`);
    }

    const recased = Object.keys(functions)
        .filter((fn) => !preserving.includes(fn))
        .sort();
    const unitNames = Object.keys(units).sort();
    const missingUnits = UNITS.filter((u) => !units[u]);
    const unmeasured = candidates.filter((fn) => !functions[fn]);

    process.stderr.write(`units measured: ${unitNames.length}/${UNITS.length}\n`);
    process.stderr.write(`functions measured: ${Object.keys(functions).length}/${candidates.length}` +
        ` (${frozen.length} kept verbatim)\n`);
    // A CSS-wide keyword is only one when it is the whole value, so it is
    // matched separately and does not belong in a per-property list.
    for (const prop of Object.keys(idents)) {
        if (!keywordList(idents[prop]).length) delete idents[prop];
    }
    const identHits = Object.values(idents).reduce((n, ks) => n + keywordList(ks).length, 0);
    process.stderr.write(`any-identifier keywords: ${identHits}` +
        ` over ${Object.keys(idents).length} properties\n`);

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-value-case.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        '//',
        '// The spelling Chrome serialises a unit and a function name with, measured by',
        '// writing each one to a real declaration in upper case and reading it back.',
        `// ${unitNames.length} of ${UNITS.length} candidate units and ${recased.length} of ${candidates.length} candidate`,
        '// function names (every function name in any mdn-data ' + MDN_DATA + ' value',
        '// syntax, plus its functions.json list) round-tripped.',
        '//',
        '// Absence is not evidence of anything except that the measurement could not',
        `// reach it: ${missingUnits.length} units (${missingUnits.join(', ')}) have no property in`,
        `// Chrome that takes them, and ${unmeasured.length} function names did not parse in any of`,
        '// the property/argument pairs offered. The engine leaves those as the author',
        '// wrote them, which is the safe direction: under-normalising keeps a page',
        '// working, over-normalising invents a spelling Chrome never uses.',
        '',
        'const std = @import("std");',
        '',
        '// Keyed on the lowercased unit; the value is Chrome\'s spelling.',
        'pub const units = std.StaticStringMap([]const u8).initComptime(.{',
        ...unitNames.map((u) => `    .{ ${zigString(u.toLowerCase())}, ${zigString(units[u].spelling)} },`),
        '});',
        '',
        '// Keyed on the lowercased function name; the value is Chrome\'s spelling.',
        'pub const functions = std.StaticStringMap([]const u8).initComptime(.{',
        ...recased.map((fn) => `    .{ ${zigString(fn.toLowerCase())}, ${zigString(functions[fn].spelling)} },`),
        '});',
        '',
        '// Functions whose value is substituted later, so Chrome keeps it as authored.',
        '// Measured: one of these anywhere in a value freezes the *whole* value --',
        `// \`width: CALC(1PX + VAR(--a))\` reads back byte for byte -- so a value`,
        '// mentioning one of them is left alone rather than just skipped over.',
        'pub const verbatim_functions = [_][]const u8{',
        ...frozen.sort().map((fn) => `    ${zigString(fn.toLowerCase())},`),
        '};',
        '',
        '// The keywords of a property that also takes an arbitrary <custom-ident>.',
        '// chrome_keywords.zig has to leave those properties\' keyword lists empty --',
        '// Chrome accepts every identifier there, so acceptance says nothing -- but it',
        '// still re-cases the real keywords, and that is the signal: `font-family:',
        '// SANS-SERIF` answers `sans-serif` where `font-family: MyOwnFont` keeps its',
        `// capitals. ${identHits} keywords over ${Object.keys(idents).length} of the ${anyIdent.length} properties.`,
        'pub const any_identifier_keywords = std.StaticStringMap([]const []const u8).initComptime(.{',
        ...Object.keys(idents).sort().map((p) =>
            `    .{ ${zigString(p)}, ${zigList(keywordList(idents[p]))} },`),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
