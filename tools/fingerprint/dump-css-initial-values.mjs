// Regenerates src/browser/webapi/css/chrome_initial_values.zig and
// src/browser/webapi/css/chrome_per_tag_values.zig from the real Chrome on this
// machine. Both come out of one run so the second is a delta against the first.
//
//   node tools/fingerprint/dump-css-initial-values.mjs [--headed]
//
// The gap this closes was measured on the Cloudflare widget (see the README
// chapter "Reading the same two files record by record"): the widget dumps
// getComputedStyle over every longhand and stringifies the result. Chrome fills
// 702 of 736 values; this engine filled 16 and answered "" to the rest, because
// CSSStyleDeclaration.getDefaultPropertyValue only knew a hand-written handful.
// "" is never a value Chrome computes for a supported longhand, so every one of
// those was a tell on its own.
//
// What is measured is the *initial* computed value: the value a longhand has on
// an element that declares nothing, in a document that declares nothing. That
// is exactly the case getDefaultPropertyValue answers, so it is the case to
// record.
//
// Two things make this more than one read of one element.
//
// Size-dependent longhands are excluded rather than recorded. `width`,
// `perspective-origin` and their kin resolve against the box, so a value read
// off one div is wrong on every differently-sized div, and a wrong number is a
// louder tell than the "" it replaced. They are found rather than listed: two
// divs of deliberately different sizes are measured and any longhand whose
// value differs between them is dropped. The dropped names are written into the
// generated file's header so the exclusion is auditable.
//
// The colour scheme is asserted, not assumed. A Chrome running dark would
// report `color: rgb(255, 255, 255)` and poison the whole table with an
// inverted palette, and nothing downstream would notice.
//
// The per-tag table is the same measurement repeated over every HTML tag. The
// flat table above is one value per longhand, read off a div, so before this
// existed every element answered a div's answer and Chrome's UA stylesheet was
// invisible: a <body> reported `margin: 0px` against Chrome's 8px, a <span>
// reported `unicode-bidi: isolate` against Chrome's normal. Each tag is
// measured in the same two differently-sized hosts and only the names that
// agree between them are kept, so a tag's own box-dependent longhands are
// dropped the same way the div's are. Only the names whose stable value differs
// from the div's are written out — the rest still come from the flat table.
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9475);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_initial_values.zig');
const perTagPath = path.join(repo, 'src/browser/webapi/css/chrome_per_tag_values.zig');

// Two boxes that share every declaration and differ only in the space they get:
// `a` is a bare div in the body, `b` is a bare div in a narrow wrapper with a
// line of text in it. Nothing on either element is declared, so every longhand
// that reads differently between them is one that resolves against the box.
//
// `fa` and `fb` are the same pair one level up: two about:blank iframes of
// deliberately different sizes. html, body and head cannot be measured by
// appending a synthetic one to the page — a createElement('html') does carry
// the UA sheet's rules, but not `view-transition-name: root`, which only the
// document's actual root element gets. Reading them out of a real document
// keeps that distinction, and two iframes keep the two-size drop test.
const PAGE = 'data:text/html,' + encodeURIComponent(
    '<!doctype html><title>css</title><meta name="color-scheme" content="light">' +
    '<body><div id=a></div><div style="width:137px"><div id=b>xy</div></div>' +
    '<iframe id=fa style="width:300px;height:150px"></iframe>' +
    '<iframe id=fb style="width:137px;height:77px"></iframe>');

// Every tag the HTML spec defines, plus one that no spec does. The unknown name
// is not filler and it is not one row among the others: the flat table's
// baseline is a *div*, and a div carries UA rules of its own (`unicode-bidi:
// isolate` among them), so falling back to it is wrong for an element the UA
// sheet says nothing about. `lp-not-a-tag` is measured to give that element its
// own fallback row. html/body/head are absent here because they are read from
// the iframes instead.
const TAGS = [
    'a', 'abbr', 'address', 'area', 'article', 'aside', 'audio', 'b', 'base',
    'bdi', 'bdo', 'blockquote', 'br', 'button', 'canvas', 'caption', 'center',
    'cite', 'code', 'col', 'colgroup', 'data', 'datalist', 'dd', 'del',
    'details', 'dfn', 'dialog', 'dir', 'div', 'dl', 'dt', 'em', 'embed',
    'fieldset', 'figcaption', 'figure', 'font', 'footer', 'form', 'frame',
    'frameset', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr',
    'i', 'iframe', 'img', 'input', 'ins', 'kbd', 'label', 'legend', 'li',
    'link', 'listing', 'main', 'map', 'mark', 'marquee', 'menu', 'meta',
    'meter', 'nav', 'nobr', 'noscript', 'object', 'ol', 'optgroup', 'option',
    'output', 'p', 'param', 'picture', 'plaintext', 'pre', 'progress', 'q',
    'rp', 'rt', 'ruby', 's', 'samp', 'script', 'search', 'section', 'select',
    'slot', 'small', 'source', 'span', 'strike', 'strong', 'style', 'sub',
    'summary', 'sup', 'table', 'tbody', 'td', 'template', 'textarea', 'tfoot',
    'th', 'thead', 'time', 'title', 'tr', 'track', 'tt', 'u', 'ul', 'var',
    'video', 'wbr', 'xmp', 'lp-not-a-tag',
];

// `display` is the one name the per-tag table must not carry. The engine
// resolves it through CSSStyleDeclaration.resolvedDisplay, which blockifies a
// flex or grid parent's children and honours a cascaded `display: none` — a
// stored per-tag string can express neither, and would shadow both.
const NOT_PER_TAG = ['display'];

// Keyed by dash-case, because that is the one spelling a declaration
// normalises to and both spellings therefore have to agree. The longhands come
// through getPropertyValue and the shorthands only exist as camelCase own
// properties, so both surfaces are read and merged: Chrome computes a value for
// far more names than the 475 it enumerates by index, and the widget reads the
// enumerable keys, not the indices.
const PROBE = `(() => {
  const dash = (s) => s.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())
    .replace(/^(webkit|moz|ms|o)-/, '-$1-');
  const read = (el) => {
    const cs = getComputedStyle(el);
    const out = {};
    for (let i = 0; i < cs.length; i++) out[cs[i]] = cs.getPropertyValue(cs[i]);
    for (const k of Object.keys(cs)) {
      if (/^\\d+$/.test(k)) continue;
      const v = cs[k];
      if (typeof v !== 'string') continue;
      const name = dash(k);
      if (!(name in out)) out[name] = v;
    }
    return out;
  };
  const a = read(document.getElementById('a'));
  const b = read(document.getElementById('b'));

  // The div's own answer, which is what the flat table stores: a name is only
  // in it when the two sizes agree and the value is not "".
  const flat = {};
  for (const n of Object.keys(a)) if (a[n] === b[n] && a[n] !== '') flat[n] = a[n];

  // Each tag goes through the same two hosts the two divs did. The pair is read
  // one tag at a time and the element is taken back out, so no tag is ever
  // measured with a sibling it would not have had on its own.
  const hostA = document.body;
  const hostB = document.getElementById('b').parentNode;
  const measure = (tag) => {
    const ea = document.createElement(tag), eb = document.createElement(tag);
    hostA.appendChild(ea); hostB.appendChild(eb);
    const ra = read(ea), rb = read(eb);
    hostA.removeChild(ea); hostB.removeChild(eb);
    return [ra, rb];
  };
  const roots = (id, which) => {
    const d = document.getElementById(id).contentDocument;
    const el = which === 'html' ? d.documentElement : which === 'head' ? d.head : d.body;
    const cs = d.defaultView.getComputedStyle(el);
    const out = {};
    for (let i = 0; i < cs.length; i++) out[cs[i]] = cs.getPropertyValue(cs[i]);
    for (const k of Object.keys(cs)) {
      if (/^\\d+$/.test(k)) continue;
      const v = cs[k];
      if (typeof v !== 'string') continue;
      const name = dash(k);
      if (!(name in out)) out[name] = v;
    }
    return out;
  };

  const skip = new Set(${JSON.stringify(NOT_PER_TAG)});
  const perTag = {}, dropped = {};
  const record = (tag, ra, rb) => {
    const rows = {}, drops = [];
    for (const n of Object.keys(ra)) {
      if (skip.has(n)) continue;
      if (ra[n] !== rb[n]) { drops.push(n); continue; }
      if (ra[n] !== (flat[n] ?? '')) rows[n] = ra[n];
    }
    perTag[tag] = rows;
    if (drops.length) dropped[tag] = drops;
  };
  for (const tag of ${JSON.stringify(TAGS)}) { const [ra, rb] = measure(tag); record(tag, ra, rb); }
  for (const which of ['html', 'body', 'head']) {
    record(which, roots('fa', which), roots('fb', which));
  }

  return JSON.stringify({
    userAgent: navigator.userAgent,
    a, b, perTag, dropped,
    iframeBodyColor: roots('fa', 'body').color,
  });
})()`;

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

const ENDPOINT = process.env.CDP_ENDPOINT ?? null;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cssinit-'));
const proc = ENDPOINT ? null : spawn(CHROME, [
    ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
], { stdio: ['ignore', 'pipe', 'pipe'] });
const ws = proc ? createWriteStream(path.join(os.tmpdir(), 'cssinit-chrome.log')) : null;
if (proc) {
    proc.stdout.pipe(ws);
    proc.stderr.pipe(ws);
}

try {
    await sleep(1600);
    const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);
    const measured = JSON.parse(await evaluate(cdp, sessionId, PROBE));
    cdp.close();

    const { a, b } = measured;
    const names = Object.keys(a);
    if (!names.length) throw new Error('the computed style enumerated nothing');
    if (Object.keys(b).length !== names.length) {
        throw new Error('the two elements enumerate different name counts');
    }
    // The merge above is only sound if both spellings of a name agree, which is
    // the assumption the dash-case key encodes. Chrome disagreeing would mean a
    // stored value is wrong under one of the two spellings.
    for (const [camel, dashed] of [['fontSize', 'font-size'], ['borderTopWidth', 'border-top-width']]) {
        void camel;
        if (!(dashed in a)) throw new Error(`${dashed} missing from the merged read`);
    }
    // The iframes carry no color-scheme meta of their own, so they are the one
    // surface the page-level assertion below does not cover.
    if (measured.iframeBodyColor !== 'rgb(0, 0, 0)') {
        throw new Error(`iframe body color read as ${measured.iframeBodyColor}, expected rgb(0, 0, 0) — this Chrome is not rendering light`);
    }
    if (a.color !== 'rgb(0, 0, 0)') {
        throw new Error(`initial color read as ${a.color}, expected rgb(0, 0, 0) — this Chrome is not rendering light`);
    }

    // Dropped for one of two reasons, both of which make a stored value wrong
    // somewhere: it resolves against the box, or Chrome itself answers "".
    const boxDependent = names.filter((n) => a[n] !== b[n]);
    const emptyInChrome = names.filter((n) => a[n] === '' && a[n] === b[n]);
    const recorded = names.filter((n) => a[n] !== '' && a[n] === b[n]);

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-initial-values.mjs — do not hand-edit.',
        '//',
        `// Measured from ${measured.userAgent}`,
        `// ${recorded.length} initial values recorded out of ${names.length} computed longhands.`,
        '//',
        '// The value each longhand computes to on an element that declares nothing,',
        '// in a document that declares nothing. That is the case',
        '// CSSStyleDeclaration.getDefaultPropertyValue answers, and answering it with',
        '// "" — which is what this engine did before this table existed — is a value',
        '// Chrome never reports for a supported longhand.',
        '//',
        `// ${boxDependent.length} longhands are deliberately absent because they resolve`,
        '// against the box, so no single stored value is right for every element. They',
        '// were found by measuring two divs of different sizes and dropping every name',
        '// that disagreed, not by listing them by hand:',
        ...chunk(boxDependent).map((l) => `//   ${l}`),
        '//',
        `// ${emptyInChrome.length} more are absent because Chrome answers "" for them too,`,
        '// so the existing fallback is already right:',
        ...chunk(emptyInChrome).map((l) => `//   ${l}`),
        '',
        'const std = @import("std");',
        '',
        '/// dash-case longhand -> the value Chrome computes when nothing declares it.',
        'pub const initial = std.StaticStringMap([]const u8).initComptime(.{',
        ...recorded.map((n) => `    .{ ${zigString(n)}, ${zigString(a[n])} },`),
        '});',
        '',
        '/// The longhands that resolve against the box. Recorded so a caller can tell',
        '/// "no initial value was measured" from "this one needs layout".',
        'pub const box_dependent = std.StaticStringMap(void).initComptime(.{',
        ...boxDependent.map((n) => `    .{ ${zigString(n)}, {} },`),
        '});',
        '',
    ];
    await fs.writeFile(outPath, lines.join('\n'));
    console.log(`wrote ${path.relative(repo, outPath)} — ${recorded.length} recorded, ${boxDependent.length} box-dependent, ${emptyInChrome.length} empty in Chrome`);
    console.log(`  box-dependent: ${boxDependent.join(', ')}`);
    console.log(`  empty in Chrome: ${emptyInChrome.join(', ')}`);

    const { perTag, dropped } = measured;
    const unknown = perTag['lp-not-a-tag'];
    if (!unknown) throw new Error('the unknown tag was not measured — the per-tag read did not run');
    delete perTag['lp-not-a-tag'];

    // A name the div dropped is answered by the layout path, which runs ahead of
    // any table. It can still look stable on a tag whose two instances happen to
    // share a box — an inline element reads `width: auto` in both hosts — so the
    // per-tag drop test does not catch it and the flat table's list has to.
    for (const rows of [...Object.values(perTag), unknown]) {
        for (const n of boxDependent) delete rows[n];
    }
    const tags = Object.keys(perTag).sort();
    if (!tags.some((t) => Object.keys(perTag[t]).length)) {
        throw new Error('no tag differed from the div, which no Chrome does');
    }
    const rowCount = tags.reduce((n, t) => n + Object.keys(perTag[t]).length, 0);
    // Every name any tag dropped, so the exclusion stays auditable the way the
    // flat table's does. A name here is answered by the layout path or not at
    // all; it is never stored.
    const droppedNames = [...new Set(Object.values(dropped).flat())].sort();

    const perTagLines = [
        '// GENERATED by tools/fingerprint/dump-css-initial-values.mjs — do not hand-edit.',
        '//',
        `// Measured from ${measured.userAgent}`,
        `// ${rowCount} values over ${tags.length} tags that differ from the div in`,
        `// chrome_initial_values.zig, plus ${Object.keys(unknown).length} for an element the UA sheet`,
        '// says nothing about.',
        '//',
        "// Chrome's UA stylesheet is per-tag and the flat table is not, so before this",
        '// existed every element answered a div\'s answer: a <body> reported',
        '// `margin: 0px` against Chrome\'s 8px, a <span> reported `unicode-bidi:',
        '// isolate` against Chrome\'s normal. That is 14 of the 26 values the Cloudflare',
        '// widget still read differently — it dumps getComputedStyle over the <body> of',
        '// a 0x0 about:blank iframe.',
        '//',
        '// Every tag measured is a key, including the ones whose row came out empty:',
        '// a miss therefore means "the UA stylesheet has no rules for this name", which',
        '// is `unknown_tag` and not the div. A name the tag has no row for still comes',
        "// from the flat table. `display` is deliberately never stored:",
        '// CSSStyleDeclaration.resolvedDisplay blockifies a flex or grid parent\'s',
        '// children and honours a cascaded `display: none`, and a stored string can',
        '// express neither.',
        '//',
        `// ${droppedNames.length} names were dropped from at least one tag because that`,
        "// tag's two differently-sized instances disagreed, so no stored value is right",
        '// for every element of it. They are answered by the layout path instead:',
        ...chunk(droppedNames).map((l) => `//   ${l}`),
        '',
        'const std = @import("std");',
        '',
        'const Values = std.StaticStringMap([]const u8);',
        '',
        "/// lowercase tag name -> the dash-case longhands Chrome's UA stylesheet gives",
        '/// that tag, wherever they differ from `chrome_initial_values.initial`.',
        '///',
        '/// A map of maps costs one sort per tag on top of the outer one, which is more',
        '/// backwards branches than a comptime block gets by default.',
        'pub const per_tag = blk: {',
        `    @setEvalBranchQuota(${Math.max(20000, rowCount * 60)});`,
        '    break :blk std.StaticStringMap(Values).initComptime(.{',
        ...tags.map((t) => `        .{ ${zigString(t)}, ${values(perTag[t])} },`),
        '    });',
        '};',
        '',
        '/// What an element the UA stylesheet has no rules for answers. Not the div:',
        '/// a div is itself styled by the UA sheet, so the flat table carries a div\'s',
        '/// rules and an unrecognised element does not have them.',
        `pub const unknown_tag = ${values(unknown)};`,
        '',
    ];
    await fs.writeFile(perTagPath, perTagLines.join('\n'));
    console.log(`wrote ${path.relative(repo, perTagPath)} — ${rowCount} values over ${tags.length} tags, ${droppedNames.length} names dropped as box-dependent somewhere`);
    console.log(`  unknown tag: ${JSON.stringify(unknown)}`);
} finally {
    try { ws?.close(); } catch { /* already closed */ }
    proc?.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}

// One tag's rows as a Values literal, spelled the way `zig fmt` wants it: a
// one-element or empty tuple takes no inner spaces, a longer one does. Emitting
// it already formatted is what keeps a regenerated file from failing the fmt
// step that `zig build` depends on.
function values(rows) {
    const names = Object.keys(rows).sort();
    const body = names.map((n) => `.{ ${zigString(n)}, ${zigString(rows[n])} }`).join(', ');
    if (!names.length) return 'Values.initComptime(.{})';
    if (names.length === 1) return `Values.initComptime(.{${body}})`;
    return `Values.initComptime(.{ ${body} })`;
}

// Wraps a name list into comment-width lines so the header stays readable.
function chunk(names) {
    if (!names.length) return ['(none)'];
    const out = [];
    let line = '';
    for (const n of names) {
        if (line && line.length + n.length + 2 > 72) { out.push(line); line = ''; }
        line += (line ? ', ' : '') + n;
    }
    if (line) out.push(line);
    return out;
}
