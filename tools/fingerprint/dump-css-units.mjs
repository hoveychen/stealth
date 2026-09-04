// Regenerates src/browser/webapi/css/chrome_units.zig from the real Chrome on
// this machine.
//
//   node tools/fingerprint/dump-css-units.mjs [--headed]
//
// `classify()` in shorthand.zig reads any run of letters after a number as a
// unit, and so `10foo` is a `<length>` to it and `width: 10foo` is stored.
// Chrome throws that declaration away. The fix needs the one thing the engine
// does not have: the list of unit spellings that exist.
//
// The list is measured twice over, because the risk here is not symmetric. A
// spelling wrongly *in* the list costs nothing -- it degrades to the length
// this engine already guessed. A real unit wrongly *out* of it refuses a
// declaration Chrome keeps, which is the one kind of wrong this whole family of
// tables is built never to be. So:
//
//   1. every unit spelled out in the CSS specs is probed, and
//   2. every alphabetic spelling up to four letters -- 475 254 of them -- is
//      probed as well, so a unit Chrome grew that nobody wrote down here is
//      found by the sweep rather than missed by the list.
//
// A spelling either property takes is a unit. The properties are chosen to
// cover every family a unit can belong to: `width` for the lengths (absolute,
// font-relative, viewport-relative, container-relative), `rotate` for the
// angles, `transition-duration` for the times, `grid-template-columns` for
// `fr`, and `font-size` as a second length reading in case one property
// refuses a unit the other takes.
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
const PORT = Number(process.env.PORT ?? 9478);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_units.zig');
const PAGE = process.env.PROBE_PAGE ?? 'http://127.0.0.1:8752/';

const WITNESSES = ['width', 'font-size', 'rotate', 'transition-duration',
    'grid-template-columns'];

// Every unit the CSS specs spell out, including the ones no property value
// takes (`dpi`, `Hz`) -- probed rather than assumed, so the file records what
// this Chrome answered rather than what the specs say.
const SPELLED = [
    'px', 'cm', 'mm', 'q', 'in', 'pt', 'pc',
    'em', 'rem', 'ex', 'rex', 'cap', 'rcap', 'ch', 'rch', 'ic', 'ric',
    'lh', 'rlh',
    'vw', 'vh', 'vi', 'vb', 'vmin', 'vmax',
    'svw', 'svh', 'svi', 'svb', 'svmin', 'svmax',
    'lvw', 'lvh', 'lvi', 'lvb', 'lvmin', 'lvmax',
    'dvw', 'dvh', 'dvi', 'dvb', 'dvmin', 'dvmax',
    'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax',
    'deg', 'grad', 'rad', 'turn',
    's', 'ms',
    'hz', 'khz',
    'dpi', 'dpcm', 'dppx', 'x',
    'fr',
];

// `1<spelling>` against every witness, in one page evaluate per batch. The
// alphabet sweep is batched by first letter so no single evaluate outstays the
// CDP timeout.
const PROBE = (spellings, witnesses) => `(() => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const taken = [];
    for (const spelling of ${JSON.stringify(spellings)}) {
        for (const property of ${JSON.stringify(witnesses)}) {
            el.style.cssText = '';
            el.style.setProperty(property, '1' + spelling);
            if (el.style.length > 0) { taken.push(spelling); break; }
        }
    }
    return JSON.stringify(taken);
})()`;

function* alphabet(length) {
    const a = 'abcdefghijklmnopqrstuvwxyz';
    if (length === 1) { yield* a; return; }
    for (const head of a) {
        for (const tail of alphabet(length - 1)) yield head + tail;
    }
}

function zigString(s) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-units-'));
const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags()];
if (!process.argv.includes('--headed')) args.push('--headless=new');
const proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(prof, 'chrome.log'));
proc.stdout.pipe(log);
proc.stderr.pipe(log);

try {
    await sleep(1600);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);
    const userAgent = await evaluate(cdp, sessionId, 'navigator.userAgent');

    const ask = async (spellings) =>
        JSON.parse(await evaluate(cdp, sessionId, PROBE(spellings, WITNESSES)));

    const found = new Set(await ask(SPELLED));
    const missedBySpec = [];
    let swept = 0;
    for (const length of [1, 2, 3, 4]) {
        // One batch per first letter at three letters and up; the whole space
        // at one and two, where it is 702 spellings.
        const batches = length <= 2 ? [[...alphabet(length)]]
            : [...alphabet(1)].map((head) =>
                [...alphabet(length - 1)].map((tail) => head + tail));
        for (const batch of batches) {
            swept += batch.length;
            for (const spelling of await ask(batch)) {
                if (!found.has(spelling)) missedBySpec.push(spelling);
                found.add(spelling);
            }
        }
        process.stderr.write(`swept ${length}-letter spellings, ${found.size} units so far\n`);
    }
    cdp.close();

    const units = [...found].sort();
    process.stderr.write(`units: ${units.length}, of ${SPELLED.length} spelled out ` +
        `and ${swept} swept\n`);
    // A unit the sweep found and the spec list did not. Printed rather than
    // folded in silently: it means this Chrome carries a unit newer than the
    // list above, which is worth knowing when the list is next read.
    if (missedBySpec.length) {
        process.stderr.write(`found by sweep, not in the spec list: ${missedBySpec.join(' ')}\n`);
    }
    // A spelling the specs carry and no property takes. Not an error -- `dpi`
    // and `Hz` are real units with no property value to sit in -- but the file
    // should not claim they were measured as units.
    const unusable = SPELLED.filter((s) => !found.has(s));

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-units.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${units.length} units, from ${SPELLED.length} spellings the specs carry plus an`,
        `// exhaustive sweep of all ${swept} alphabetic spellings up to four letters.`,
        '//',
        '// Which runs of letters after a number are a unit at all. Without this the',
        '// engine reads any of them as one, so `10foo` classifies as a `<length>` and',
        '// `width: 10foo` is stored -- Chrome throws that declaration away.',
        '//',
        '// The class a unit belongs to is not here: `classify` already reads `deg` as an',
        '// angle and `s` as a time, and this only answers whether the spelling exists.',
        '//',
        `// Spelled out in the specs and taken by no property value, so not here:`,
        `// ${unusable.join(', ')}.`,
        '',
        'const std = @import("std");',
        '',
        '/// Every unit spelling this Chrome takes, lower-cased. Units are',
        '/// case-insensitive -- `10PX` is `10px` -- so a lookup has to fold first.',
        'pub const units = std.StaticStringMap(void).initComptime(.{',
        ...units.map((u) => `    .{ ${zigString(u)}, {} },`),
        '});',
        '',
        '/// The longest spelling in the table, so a lookup can fold a unit into a',
        '/// buffer this size and answer no for anything longer without looking.',
        `pub const longest = ${Math.max(...units.map((u) => u.length))};`,
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
