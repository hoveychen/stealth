// Recovers the ladder Chrome builds a `line-height: normal` box from, for every
// family in the metrics table, and regenerates src/browser/font_line_box.zig.
//
//   node tools/fingerprint/dump-line-boxes.mjs [--headed] [--only serif,Arial]
//   node tools/fingerprint/dump-line-boxes.mjs --verify        # 0.01 sweep too
//
// font_metrics.zig holds the box at every INTEGER size, measured. Between the
// integers it used to scale the last entry linearly, and linear is the one thing
// this is not: 297 of 301 fractional sizes came out wrong, while all 13 integer
// ones were right. The shape of the error says why -- Chrome's answer is always
// on a 1/dpr grid, and a ratio times a size is not.
//
// What Blink actually computes, at a device pixel ratio of 2:
//
//     S = 2 * size                                    (device px)
//     L = R(gap*S)               A = R(asc*S) + L/2   D = R(desc*S) + (L - L/2)
//     ascent  = A + [hack] R(0.15 * (A + D))
//     height  = ascent + D                            (both /2 back into CSS px)
//     R(x) = floor(x + 0.5)      -- Skia rounds half away from zero, `/` floors
//
// The line gap is rounded ONCE and then split, floor of half above the baseline
// and the rest below. Two independent gap ratios would be a strictly more
// general model and it is the wrong one: Arial's gap steps at 22.93, 53.50 and
// 84.06px -- one spacing, two phases -- which the split produces and no pair of
// ratios does.
//
// `hack` is Blink's Safari-compat ascent adjustment, which it still carries for
// Times, Helvetica and Courier (so for `serif` and `sans-serif`, which resolve
// to two of them). Its steps land on the ascent ladder's OWN lattice, which is
// why fitting the line box alone kept producing a phantom third ladder: in the
// sum the hack is indistinguishable from an extra ascent. Measuring the ascent
// on its own -- a zero-height inline-block sits exactly on the baseline -- is
// what splits them, so this tool reads the baseline, not just the height.
//
// The fit is interval intersection, not least squares. Each reading pins R*S
// into a window one device pixel wide; the sweep's windows intersect down to a
// few 1e-6, which is exact for every size in range. A least-squares ratio is off
// by ~1e-3 and puts a dozen steps in the wrong place.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT) || 9467;
const headed = process.argv.includes('--headed');
const verify = process.argv.includes('--verify');
const onlyArg = process.argv[process.argv.indexOf('--only') + 1];
const only = process.argv.includes('--only') ? onlyArg.split(',') : null;
const surveyPath = path.join(repo, 'tools/fingerprint/results/reference-chrome-fonts.json');
const outPath = path.join(repo, 'src/browser/font_line_box.zig');

// The fit sweep. 0.1 over the whole tabulated range is 1191 readings, which is
// two orders of magnitude more than the four unknowns need; the density that
// matters is not how fine the step is but how many DIFFERENT sizes constrain
// the same ratio, and a step that divides 0.5 evenly would not.
const FIT_STEP = 0.1;
const SWEPT_SIZES = 120;
// The held-out check, ten times denser, on the families a fingerprinting script
// actually names. `--verify` is off by default because it is 11901 layouts a
// family and the fit does not need it.
const VERIFY_FAMILIES = ['serif', 'sans-serif', 'monospace', 'system-ui', 'cursive', 'fantasy', 'Arial', 'Times', 'Helvetica', 'Courier'];

const R = (x) => Math.floor(x + 0.5);

// One family's sweep, in the page: the line box and the baseline at every size.
const measure = (quoted, step) => `(() => {
  const host = document.createElement('div');
  host.setAttribute('style', 'position:absolute;left:-9999px;top:0;width:4000px');
  document.body.appendChild(host);
  const line = document.createElement('div');
  // A zero-height inline-block has no in-flow line box of its own, so its
  // baseline is its bottom margin edge -- which is the line's baseline, and with
  // no height its top reports it directly. It contributes an ascent of 0 and a
  // descent of 0, so it cannot widen the box it is measuring.
  const mark = document.createElement('span');
  mark.setAttribute('style', 'display:inline-block;width:0;height:0');
  line.appendChild(mark);
  line.appendChild(document.createTextNode('Hxg'));
  host.appendChild(line);
  const rows = [];
  const step = ${step};
  const n = Math.round(${SWEPT_SIZES} / step);
  for (let i = Math.round(1 / step); i <= n; i++) {
    const size = Math.round(i * step * 100) / 100;
    line.setAttribute('style', 'font-size:' + size + 'px;font-family:${quoted};line-height:normal');
    const box = line.getBoundingClientRect();
    rows.push([size, box.height, mark.getBoundingClientRect().top - box.top]);
  }
  host.remove();
  return JSON.stringify({ dpr: devicePixelRatio, rows });
})()`;

/// The ratio most of the readings agree on, and how many that is.
///
/// Each reading of `n` device px at size `s` says the ratio lies in the window
/// `[(n-0.5)/S, (n+0.5)/S)`, so the fit is the point covered by the most
/// windows -- an interval-overlap sweep, not least squares. It has to tolerate
/// misses rather than intersect strictly: CoreText's own quantisation puts a
/// handful of readings a device pixel off a clean ratio (six of 11901 for
/// `cursive`), and one such reading empties a strict intersection.
function bestRatio(obs) {
    const ev = [];
    for (const [s, n] of obs) {
        ev.push([(n - 0.5) / (2 * s), 1], [(n + 0.5) / (2 * s), -1]);
    }
    ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    let live = 0, best = -1, lo = 0, hi = 0;
    for (let i = 0; i < ev.length; i++) {
        live += ev[i][1];
        if (live > best && i + 1 < ev.length) { best = live; lo = ev[i][0]; hi = ev[i + 1][0]; }
    }
    return { r: (lo + hi) / 2, hits: best };
}

/// The whole box, at one candidate line gap. The gap is rounded ONCE, on the
/// device grid, and then split: the ascent takes the floor of half of it and
/// the descent the rest. That is the half-leading rule, and it is what makes
/// Arial work -- its gap ladder steps at 22.93, 53.50 and 84.06px, which is one
/// spacing with two different phases, and no pair of independent ratios
/// produces that. With the split the same face goes from 79% to 99.9%.
///
/// The two metric ratios are then solved against the gap by overlap, one side
/// each, because with the gap fixed each side is a single ladder again.
function fitAtGap(asc, desc, gap) {
    const half = (s) => { const g = R(gap * 2 * s); return [Math.floor(g / 2), g - Math.floor(g / 2)]; };
    const a1 = bestRatio(asc.map(([s, n]) => [s, n - half(s)[0]])).r;
    const d1 = bestRatio(desc.map(([s, n]) => [s, n - half(s)[1]])).r;
    let k = 0;
    for (let i = 0; i < asc.length; i++) {
        const [s, n] = asc[i], [ga, gd] = half(s);
        if (R(a1 * 2 * s) + ga === n && R(d1 * 2 * s) + gd === desc[i][1]) k++;
    }
    return { a1, d1, gap, hits: k };
}

/// The gap is swept and everything else solved against it. Coarse then fine:
/// the gap is small (Arial's is 67/2048) and a 1e-5 sweep of the whole
/// plausible span would be 12000 fits a family where 240 + 100 is the same
/// answer.
function fitSplit(asc, desc, gapMax = 0.12) {
    let best = fitAtGap(asc, desc, 0);
    for (let g = 0; g <= gapMax; g += 5e-4) {
        const f = fitAtGap(asc, desc, g);
        if (f.hits > best.hits) best = f;
    }
    for (let g = Math.max(0, best.gap - 5e-4); g <= best.gap + 5e-4; g += 1e-5) {
        const f = fitAtGap(asc, desc, g);
        if (f.hits > best.hits) best = f;
    }
    return best;
}

const halfGap = (f, size, dpr) => {
    const g = R(f.gap * dpr * size);
    return [Math.floor(g / 2), g - Math.floor(g / 2)];
};

function ascentOf(f, size, dpr, d) {
    const A = R(f.a1 * dpr * size) + halfGap(f, size, dpr)[0];
    return A + (f.hack ? R(0.15 * (A + d)) : 0);
}

const hits = (rows, dpr, f) => rows.reduce((n, [s, h, a]) => {
    const d = R(f.d1 * dpr * s) + halfGap(f, s, dpr)[1];
    const asc = ascentOf(f, s, dpr, d);
    return n + (asc === Math.round(a * dpr) && asc + d === Math.round(h * dpr) ? 1 : 0);
}, 0);

/// Blink's Safari-compat ascent adjustment, which it still applies to Times,
/// Helvetica and Courier. It is invisible in the line box -- its steps fall on
/// the ascent ladder's own lattice -- so it is recovered by inverting it per
/// reading: a reading can admit two raw ascents where the adjustment skips a
/// value, so only the unambiguous ones are fitted and all of them verify.
function fitHack(rows, dpr, plain) {
    const pinned = [];
    for (const [s, h, a] of rows) {
        const want = Math.round(a * dpr);
        const d = Math.round((h - a) * dpr);
        const cand = [];
        for (let A = Math.max(0, Math.floor(want / 1.3)); A <= want; A++) {
            if (A + R(0.15 * (A + d)) === want) cand.push(A);
        }
        if (cand.length === 1) pinned.push([s, cand[0]]);
    }
    if (pinned.length < 10) return null;
    const desc = rows.map(([s, h, a]) => [s, Math.round((h - a) * dpr)]);
    const f = { ...fitSplit(pinned, desc), hack: true };
    return hits(rows, dpr, f) > plain ? f : null;
}

function fit(rows, dpr) {
    const asc = rows.map(([s, , a]) => [s, Math.round(a * dpr)]);
    const desc = rows.map(([s, h, a]) => [s, Math.round((h - a) * dpr)]);
    const plain = { ...fitSplit(asc, desc), hack: false };
    return fitHack(rows, dpr, hits(rows, dpr, plain)) ?? plain;
}

// A CSS family name needs quoting unless it is a keyword; quoting a keyword
// turns it into a family name Chrome will not resolve.
const KEYWORDS = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', 'math', 'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded']);
const cssName = (f) => (KEYWORDS.has(f) ? f : `"${f}"`);
const bare = (f) => f.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');

const survey = JSON.parse(await fs.readFile(surveyPath, 'utf8'));
let families = survey.kept.map((k) => k.family);
if (only) families = families.filter((f) => only.includes(f));

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-line-boxes-'));
const flags = [
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check',
    // The scale IS the grid the ladder rounds onto, so it is pinned rather than
    // left to whichever display the run lands on. Two is what this engine's
    // persona claims, and it is read back off the page below.
    '--force-device-scale-factor=2',
];
if (!headed) flags.push('--headless=new');
const proc = spawn(CHROME, flags, { stdio: 'ignore' });

const fitted = [];
const failed = [];
try {
    for (let i = 0; i < 100; i++) {
        try { if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) break; } catch {}
        await sleep(100);
    }
    const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const sweep = async (family, step) => {
        const r = await cdp.send('Runtime.evaluate',
            { expression: measure(cssName(family), step), returnByValue: true }, sessionId);
        if (r.exceptionDetails) throw new Error(`${family}: ${r.exceptionDetails.text}`);
        const t = JSON.parse(r.result.value);
        if (t.dpr !== 2) throw new Error(`devicePixelRatio is ${t.dpr}, not 2 — the ladder would be fitted on the wrong grid`);
        return t;
    };
    for (const family of families) {
        const { dpr, rows } = await sweep(family, FIT_STEP);
        const f = fit(rows, dpr);
        if (!f) { failed.push(family); process.stderr.write(`no fit: ${family}\n`); continue; }
        const n = hits(rows, dpr, f);
        let verified = null;
        if (verify && VERIFY_FAMILIES.includes(family)) {
            const v = await sweep(family, 0.01);
            verified = `${hits(v.rows, v.dpr, f)}/${v.rows.length}`;
        }
        fitted.push({ family, ...f, fitHits: n, fitRows: rows.length, verified });
        process.stderr.write(`${family}: asc=${f.a1.toFixed(7)} desc=${f.d1.toFixed(7)} ` +
            `gap=${f.gap.toFixed(7)} hack=${f.hack} ` +
            `${n}/${rows.length}${verified ? `  verify@0.01 ${verified}` : ''}\n`);
    }
    cdp.close();
} finally {
    proc.kill('SIGKILL');
    await fs.rm(profile, { recursive: true, force: true }).catch(() => {});
}

const total = fitted.reduce((n, f) => n + f.fitHits, 0);
const rowsTotal = fitted.reduce((n, f) => n + f.fitRows, 0);
process.stderr.write(`\n${fitted.length} families fitted, ${failed.length} not; ` +
    `${total}/${rowsTotal} readings exact\n`);

const head = `// GENERATED by tools/fingerprint/dump-line-boxes.mjs -- do not edit.
//
// The ladder Chrome builds a \`line-height: normal\` box from. font_metrics.zig
// carries the box measured at every integer size; this carries the rule that
// produces it at every size in between, where scaling the table linearly is
// wrong for all but a handful of fractional sizes.
//
//     S = size * device_pixel_ratio
//     L = R(gap*S)   A = R(asc*S) + L/2   D = R(desc*S) + (L - L/2)
//     ascent  = A + [hack] R(0.15 * (A + D))
//     descent = D                                (both back into CSS px)
//
// \`hack\` is Blink's Safari-compat ascent adjustment, which it still applies to
// Times, Helvetica and Courier -- and so to \`serif\` and \`sans-serif\`, which
// resolve to two of them on this persona. Its steps fall on the ascent ladder's
// own lattice, so it is not recoverable from the line box alone; the tool reads
// the baseline separately to tell the two apart.

pub const Ladder = struct {
    asc: f64,
    desc: f64,
    /// The face's line gap. Rounded ONCE on the device grid and then split --
    /// floor of half above the baseline, the rest below -- which is the
    /// half-leading rule. Fitting the two sides as independent ratios instead
    /// reproduces 79% of Arial's sizes where this reproduces 99.9%.
    gap: f64,
    hack: bool,

    /// The ascent and descent a line stands on at this size and scale. Rounding
    /// is \`floor(x + 0.5)\`, which is what Skia does -- \`@round\` in Zig rounds
    /// half away from zero too, so the two agree for the positive values here.
    pub fn box(self: Ladder, size: f64, dpr: f64) struct { ascent: f64, descent: f64 } {
        const s = size * dpr;
        const leading = @round(self.gap * s);
        const above = @divFloor(leading, 2);
        const a = @round(self.asc * s) + above;
        const d = @round(self.desc * s) + (leading - above);
        const asc = a + if (self.hack) @round(0.15 * (a + d)) else 0;
        return .{ .ascent = asc / dpr, .descent = d / dpr };
    }
};
`;

// The hit rate rides along on every line. It is not decoration: CoreText
// quantises some faces in a way no ratio reproduces -- Arial's ascent slips a
// device pixel over four bands of the range and lands at 79%, where most
// families are exact -- and a reader comparing a value against Chrome needs to
// know which of the two they are looking at before they call it a bug.
const body = fitted.map((f) =>
    `pub const ${bare(f.family)}: Ladder = .{ .asc = ${f.a1}, ` +
    `.desc = ${f.d1}, .gap = ${f.gap}, .hack = ${f.hack} }; // ${f.fitHits}/${f.fitRows}`)
    .join('\n');

const exact = fitted.filter((f) => f.fitHits === f.fitRows).length;
const summary = `// Fitted against Chrome over 1..${SWEPT_SIZES}px in ${FIT_STEP}px steps:
// ${exact} of ${fitted.length} families exact at every size, ${total} of ${rowsTotal} readings overall.
`;
await fs.writeFile(outPath, `${head}${summary}\n${body}\n`);
await fs.writeFile(
    path.join(repo, 'tools/fingerprint/results/reference-chrome-line-boxes.json'),
    `${JSON.stringify({ note: 'Per-family line box ladders fitted by dump-line-boxes.mjs. The Zig table is the product; this is the fit report.', fitted, failed }, null, 1)}\n`,
);
process.stderr.write(`wrote ${outPath}\n`);
