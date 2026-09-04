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
// Four facts come out, and probe-css17 measured that they are independent
// rather than several readings of one rule:
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
//   number_range the interval of bare `<number>` the property takes, and
//                whether it takes only whole ones. `font-weight` is [1, 1000]
//                and takes 399.5; `z-index` is unbounded both ways and refuses
//                1.5; `opacity` is in neither of the lists above nor this one,
//                because it takes -1 and 2 and clamps them later.
//   needs_unit   the property takes some numeric class and refuses every bare
//                number including `0` -- `rotate: 90` and
//                `transition-duration: 1`, where the sign lists have nothing to
//                say and a unitless zero would otherwise walk in as a length.
//
// A property that accepts no numeric class at all is in none of the lists:
// there is nothing to be out of range. Absence means "not measured to refuse",
// never "measured to accept" -- the engine reads these lists as a licence to
// refuse and keeps anything they do not cover, so a name missing here degrades
// to the whole-value keep this engine did before the lists existed.
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

// Bare numbers, spread over the boundaries the properties in this engine are
// known to have and a few that nothing is expected to sit on. They are probed
// as written -- `-0` is not `0`, and a property that refuses one and takes the
// other would be invisible if the grid held a single spelling of zero.
const GRID = [
    '-1000000', '-1001', '-1000', '-100', '-2', '-1.5', '-1', '-0.5', '-0',
    '0', '0.5', '1', '1.5', '2', '2.5', '100', '399.5', '1000', '1001',
    '1000000',
];

const PROBE = (names, battery, grid) => `(() => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const takes = (property, value) => {
        el.style.cssText = '';
        el.style.setProperty(property, value);
        return el.style.length > 0;
    };
    // Far enough out that a property still taking it has no bound this side.
    const HUGE = 1e9;
    const fmt = (n) => {
        if (Number.isInteger(n)) return String(n);
        return n.toFixed(12).replace(/0+$/, '').replace(/\\.$/, '');
    };
    // The smallest value the property still takes, given a rejected \`lo\` and an
    // accepted \`hi\`. Whole numbers are bisected as whole numbers: a property
    // that refuses 1.5 would otherwise have every probe below its bound
    // rejected for the wrong reason and converge on the anchor it started from.
    const floor = (property, lo, hi, integer) => {
        if (integer) {
            while (hi - lo > 1) {
                const mid = Math.floor((lo + hi) / 2);
                if (takes(property, fmt(mid))) hi = mid; else lo = mid;
            }
            return hi;
        }
        for (let i = 0; i < 200 && hi - lo > 1e-9; i++) {
            const mid = (lo + hi) / 2;
            if (takes(property, fmt(mid))) hi = mid; else lo = mid;
        }
        return hi;
    };
    const ceil = (property, lo, hi, integer) => {
        if (integer) {
            while (hi - lo > 1) {
                const mid = Math.floor((lo + hi) / 2);
                if (takes(property, fmt(mid))) lo = mid; else hi = mid;
            }
            return lo;
        }
        for (let i = 0; i < 200 && hi - lo > 1e-9; i++) {
            const mid = (lo + hi) / 2;
            if (takes(property, fmt(mid))) lo = mid; else hi = mid;
        }
        return lo;
    };
    // A bound bisection converged on is a bound only if it survives being
    // written down: the value itself taken, and the value one step outside it
    // refused. A bisection that ran out of iterations, or one whose limit is
    // not a number anybody would write, fails this and is reported as unknown.
    const settle = (property, x, integer, below) => {
        const step = integer ? 1 : Math.max(1, Math.abs(x)) * 1e-6;
        const snapped = integer ? Math.round(x) : Math.round(x * 1e6) / 1e6;
        if (Math.abs(snapped - x) > (integer ? 0 : 1e-6)) return null;
        if (!takes(property, fmt(snapped))) return null;
        if (takes(property, fmt(snapped + (below ? -step : step)))) return null;
        return snapped;
    };

    const out = {};
    for (const property of ${JSON.stringify(names)}) {
        const row = { classes: {}, grid: {} };
        for (const [cls, pair] of Object.entries(${JSON.stringify(battery)})) {
            row.classes[cls] = [takes(property, pair[0]), takes(property, pair[1])];
        }
        const grid = ${JSON.stringify(grid)};
        for (const value of grid) row.grid[value] = takes(property, value);
        const accepted = grid.filter((v) => row.grid[v]).map(Number);
        row.bare = accepted.length > 0;
        if (row.bare) {
            row.integer = accepted.every(Number.isInteger);
            row.min = takes(property, fmt(-HUGE)) ? null
                : floor(property, -HUGE, Math.min(...accepted), row.integer);
            row.max = takes(property, fmt(HUGE)) ? null
                : ceil(property, Math.max(...accepted), HUGE, row.integer);
            row.unsettled = [];
            if (row.min !== null) {
                const settled = settle(property, row.min, row.integer, true);
                if (settled === null) row.unsettled.push('min~' + row.min);
                else row.min = settled;
            }
            if (row.max !== null) {
                const settled = settle(property, row.max, row.integer, false);
                if (settled === null) row.unsettled.push('max~' + row.max);
                else row.max = settled;
            }
            // Every reading the grid holds, replayed against the interval. An
            // acceptance that is not one contiguous run is not an interval at
            // all, and saying so here is what keeps it out of the table.
            row.contradictions = grid.filter((v) => {
                const n = Number(v);
                const inside = (row.min === null || n >= row.min) &&
                    (row.max === null || n <= row.max) &&
                    (!row.integer || Number.isInteger(n));
                return inside !== row.grid[v];
            });
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

// Which properties the value-class table already answers for, and whether
// `<number>` is among the classes it grants. A property it grades without a
// number class already refuses every bare number but `0` -- `classify` reads a
// unitless zero as a length too -- so writing that same refusal down again as
// an interval of [0, 0] would fill the table with a rule already in force.
async function numberGraded() {
    const source = await fs.readFile(
        path.join(repo, 'src/browser/webapi/css/chrome_shorthands.zig'), 'utf8');
    const block = source.slice(source.indexOf('pub const value_classes'));
    const graded = new Map();
    for (const m of block.matchAll(/^\s*\.\{ "([a-zA-Z-]+)", &\.\{([^}]*)\} \},$/gm)) {
        graded.set(m[1], m[2].includes('.number'));
    }
    return graded;
}

function zigString(s) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-bounds-'));
const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags()];
if (!process.argv.includes('--headed')) args.push('--headless=new');
const proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
const log = createWriteStream(path.join(prof, 'chrome.log'));
proc.stdout.pipe(log);
proc.stderr.pipe(log);

try {
    const names = await propertyNames();
    const graded = await numberGraded();
    process.stderr.write(`property names: ${names.length}\n`);

    await sleep(1600);
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { sessionId } = await newPage(cdp);
    await cdp.send('Page.navigate', { url: PAGE }, sessionId);
    await sleep(1200);
    const { userAgent, out } = JSON.parse(
        await evaluate(cdp, sessionId, PROBE(names, BATTERY, GRID)));
    cdp.close();

    if (process.env.RAW) {
        await fs.writeFile(process.env.RAW, JSON.stringify(out, null, 1));
        process.stderr.write(`raw readings: ${process.env.RAW}\n`);
    }

    const noNegative = [];
    const noPercent = [];
    const needsUnit = [];
    const ranges = [];
    // A property that refuses the negative of some classes it takes and not
    // others would make `no_negative` a lie. Measured: none do -- but the
    // check prints rather than assumes, because a Chrome that grew one would
    // otherwise land here silently as a rule the engine over-applies.
    const mixed = [];
    // A bare-number acceptance that is not one interval, and a bisection that
    // did not settle on a bound anybody would write down. Both are printed and
    // neither is written: an interval the readings contradict would refuse a
    // declaration Chrome keeps, which is the one kind of wrong this table is
    // built never to be.
    const ragged = [];
    let numeric = 0;
    for (const name of names) {
        const row = out[name];
        const taken = Object.keys(BATTERY).filter((cls) => row.classes[cls][0]);
        if (taken.length === 0) continue;
        numeric++;
        const refusing = taken.filter((cls) => !row.classes[cls][1]);
        if (refusing.length === taken.length) noNegative.push(name);
        else if (refusing.length > 0) mixed.push(`${name} (${refusing.join(',')})`);
        if (row.classes.length[0] && !row.classes.percent[0]) noPercent.push(name);

        if (!row.bare) { needsUnit.push(name); continue; }
        if (row.contradictions.length > 0 || row.unsettled.length > 0) {
            ragged.push(`${name} (${[...row.contradictions, ...row.unsettled].join(' ')})`);
            continue;
        }
        if (row.min === null && row.max === null && !row.integer) continue;
        // [0, 0] on a property the class table already grades without a number
        // class: the same refusal, written twice.
        if (row.min === 0 && row.max === 0 && graded.get(name) === false) continue;
        ranges.push([name, row]);
    }
    process.stderr.write(`numeric properties: ${numeric} of ${names.length}\n`);
    process.stderr.write(`no_negative: ${noNegative.length}, no_percent: ${noPercent.length}, ` +
        `number_range: ${ranges.length}, needs_unit: ${needsUnit.length}\n`);
    if (mixed.length) {
        process.stderr.write(`mixed sign rules (NOT in no_negative): ${mixed.join(', ')}\n`);
    }
    if (ragged.length) {
        process.stderr.write(`not one interval (NOT in number_range): ${ragged.join(', ')}\n`);
    }

    // A one-point interval holds no fraction to refuse, so the whole-number
    // flag there would be a reading of the bound rather than of a rule. Most
    // of this table is such a point: a length property takes `0` and no other
    // bare number, and `.min = 0, .max = 0` is the whole of what it says.
    const field = (row) => {
        const parts = [];
        if (row.min !== null) parts.push(`.min = ${row.min}`);
        if (row.max !== null) parts.push(`.max = ${row.max}`);
        if (row.integer && !(row.min !== null && row.min === row.max)) {
            parts.push('.integer = true');
        }
        return parts.join(', ');
    };

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
        '/// Takes a numeric class and refuses every bare number, `0` included. The',
        '/// sign lists cannot say this and neither can the value classes, which read a',
        '/// unitless zero as a length: `rotate: 0` and `transition-duration: 0` are',
        '/// refused where `rotate: 0deg` and `transition-duration: 0s` are kept.',
        'pub const needs_unit = std.StaticStringMap(void).initComptime(.{',
        ...needsUnit.map((n) => `    .{ ${zigString(n)}, {} },`),
        '});',
        '',
        '/// The interval of bare `<number>` a property takes. A bound absent here is',
        '/// one the property does not have -- `z-index` is `.integer` alone and takes',
        '/// -1000000 as readily as 1000000 -- and a property absent altogether has',
        '/// neither bound nor a whole-number rule, which is how `opacity` (takes -1,',
        '/// takes 2, clamps afterwards) is told apart from `flex-grow` (refuses -1).',
        '///',
        '/// Both bounds are inclusive, and both were bisected and then written down',
        '/// only after the value itself was taken and the next one outside refused.',
        'pub const Range = struct {',
        '    min: ?f64 = null,',
        '    max: ?f64 = null,',
        '    integer: bool = false,',
        '};',
        '',
        'pub const number_range = std.StaticStringMap(Range).initComptime(.{',
        ...ranges.map(([n, row]) => `    .{ ${zigString(n)}, Range{ ${field(row)} } },`),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
} finally {
    proc.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
