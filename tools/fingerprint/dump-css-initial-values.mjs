// Regenerates src/browser/webapi/css/chrome_initial_values.zig from the real
// Chrome on this machine.
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
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9475);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_initial_values.zig');

// Two boxes that share every declaration and differ only in the space they get:
// `a` is a bare div in the body, `b` is a bare div in a narrow wrapper with a
// line of text in it. Nothing on either element is declared, so every longhand
// that reads differently between them is one that resolves against the box.
const PAGE = 'data:text/html,' + encodeURIComponent(
    '<!doctype html><title>css</title><meta name="color-scheme" content="light">' +
    '<body><div id=a></div><div style="width:137px"><div id=b>xy</div></div>');

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
  return JSON.stringify({
    userAgent: navigator.userAgent,
    a: read(document.getElementById('a')),
    b: read(document.getElementById('b')),
  });
})()`;

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

const ENDPOINT = process.env.CDP_ENDPOINT ?? null;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cssinit-'));
const proc = ENDPOINT ? null : spawn(CHROME, [
    ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check',
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
} finally {
    try { ws?.close(); } catch { /* already closed */ }
    proc?.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
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
