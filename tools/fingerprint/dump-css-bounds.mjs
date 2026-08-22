// Regenerates src/browser/webapi/css/chrome_bounds.zig from the real Chrome on
// this machine.
//
//   node tools/fingerprint/dump-css-bounds.mjs [--headed]
//
// `shorthand.zig`'s `accepts()` answers which value *classes* a property takes,
// and that is all it answers: `-10px` and `10px` are both a `<length>`, so the
// table cannot tell `margin` from `padding`. probe-css17.js measured that
// Chrome throws `padding: -10px` away and keeps `margin: -10px`, and that the
// split is per property with nothing in the grammar to derive it from. This
// fills that in, for every property name the engine knows.
//
// Two facts come out, and probe-css17 measured that they are independent rather
// than two readings of one rule:
//
//   no_negative  the property takes a positive value of every numeric class it
//                accepts and refuses the negative of each. Sizes are here
//                (`padding`, `width`, a radius, a border width); offsets are
//                not (`margin`, `top`, `letter-spacing`).
//   no_percent   the property takes a length and refuses a percentage, of
//                either sign. `border-width`, `outline-width`, `column-width`,
//                `border-spacing`, `perspective` -- and `outline-offset`, which
//                is in this list and *not* in the one above, which is what
//                makes the two orthogonal rather than one rule seen twice.
//
// A property that accepts no numeric class at all is in neither list: there is
// nothing to be out of range. Absence means "not measured to refuse", never
// "measured to accept" -- the engine reads these lists as a licence to refuse
// and keeps anything they do not cover, so a name missing here degrades to the
// whole-value keep this engine did before the lists existed.
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
const PORT = Number(process.env.PORT ?? 9477);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_bounds.zig');
// A trustworthy origin, the same one every other CSS measurement here uses.
const PAGE = process.env.PROBE_PAGE ?? 'http://127.0.0.1:8752/';

// One positive and one negative per numeric class. A class whose positive form
// the property refuses is not a class it takes, so its negative says nothing.
const BATTERY = {
    length: ['1px', '-1px'],
    percent: ['1%', '-1%'],
    number: ['1', '-1'],
    time: ['1s', '-1s'],
    angle: ['1deg', '-1deg'],
};

const PROBE = (names, battery) => `(() => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const takes = (property, value) => {
        el.style.cssText = '';
        el.style.setProperty(property, value);
        return el.style.length > 0;
    };
    const out = {};
    for (const property of ${JSON.stringify(names)}) {
        const row = {};
        for (const [cls, pair] of Object.entries(${JSON.stringify(battery)})) {
            row[cls] = [takes(property, pair[0]), takes(property, pair[1])];
        }
        out[property] = row;
    }
    return JSON.stringify({ userAgent: navigator.userAgent, out });
})()`;

// The engine's own list of property names, so the table covers exactly what it
// can be asked about: the computed longhands plus every alias (the shorthands
// and the legacy -webkit- spellings). The alias list is spelled the way the
// IDL attribute is -- `borderRadius`, `webkitBorderRadius` -- and `setProperty`
// takes neither, so each is turned back into the dash-case name it stands for.
async function propertyNames() {
    const source = await fs.readFile(
        path.join(repo, 'src/browser/webapi/css/chrome_properties.zig'), 'utf8');
    const names = new Set();
    for (const m of source.matchAll(/^\s*"([a-zA-Z-]+)",$/gm)) {
        const name = m[1];
        if (name.includes('-')) { names.add(name); continue; }
        const dashed = name.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
        names.add(/^(webkit|moz|ms|epub)/.test(name) ? '-' + dashed : dashed);
    }
    return [...names].sort();
}

function zigString(s) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-bounds-'));
const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check'];
if (!process.argv.includes('--headed')) args.push('--headless=new');
const proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(prof, 'chrome.log'));
proc.stdout.pipe(log);
proc.stderr.pipe(log);

try {
    const names = await propertyNames();
    process.stderr.write(`property names: ${names.length}\n`);

    await sleep(1600);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);
    const { userAgent, out } = JSON.parse(
        await evaluate(cdp, sessionId, PROBE(names, BATTERY)));
    cdp.close();

    const noNegative = [];
    const noPercent = [];
    // A property that refuses the negative of some classes it takes and not
    // others would make `no_negative` a lie. Measured: none do -- but the
    // check prints rather than assumes, because a Chrome that grew one would
    // otherwise land here silently as a rule the engine over-applies.
    const mixed = [];
    let numeric = 0;
    for (const name of names) {
        const row = out[name];
        const taken = Object.keys(BATTERY).filter((cls) => row[cls][0]);
        if (taken.length === 0) continue;
        numeric++;
        const refusing = taken.filter((cls) => !row[cls][1]);
        if (refusing.length === taken.length) noNegative.push(name);
        else if (refusing.length > 0) mixed.push(`${name} (${refusing.join(',')})`);
        if (row.length[0] && !row.percent[0]) noPercent.push(name);
    }
    process.stderr.write(`numeric properties: ${numeric} of ${names.length}\n`);
    process.stderr.write(`no_negative: ${noNegative.length}, no_percent: ${noPercent.length}\n`);
    if (mixed.length) {
        process.stderr.write(`mixed sign rules (NOT in no_negative): ${mixed.join(', ')}\n`);
    }

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-bounds.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${numeric} of ${names.length} property names take a numeric value at all.`,
        '//',
        '// Which values a property refuses on range rather than on shape. The value',
        '// classes in chrome_shorthands.zig cannot answer this: `-10px` and `10px` are',
        '// both a `<length>`, and `margin` takes one where `padding` does not.',
        '//',
        '// Absence is not acceptance. The engine reads these as a licence to refuse a',
        '// declaration and keeps everything they do not name, so a property missing',
        '// here behaves the way the whole engine did before they existed.',
        '',
        'const std = @import("std");',
        '',
        '/// Takes a positive value of every numeric class it accepts and refuses the',
        '/// negative of each. Negative zero is not negative and is not refused --',
        '/// `padding: -0px` reads back `0px`, measured.',
        'pub const no_negative = std.StaticStringMap(void).initComptime(.{',
        ...noNegative.map((n) => `    .{ ${zigString(n)}, {} },`),
        '});',
        '',
        '/// Takes a length and refuses a percentage of either sign. Separate from the',
        '/// list above and not implied by it: `outline-offset` is here and not there.',
        'pub const no_percent = std.StaticStringMap(void).initComptime(.{',
        ...noPercent.map((n) => `    .{ ${zigString(n)}, {} },`),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
