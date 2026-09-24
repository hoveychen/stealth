// The kerning pairs Chrome applies in LAYOUT that it does not apply in the
// canvas, measured out of real Chrome.
//
//   node tools/fingerprint/dump-space-kerning.mjs [--only serif,sans-serif] [--headed]
//
// `dump-kerning.mjs` measures every pair with `measureText`, and its range
// starts at U+0020 -- yet not one of the 265 840 pairs it wrote down has a
// space on either side. That is not because Chrome does not kern them. It is
// because the canvas does not:
//
//   'AVATAR To Wo' at 16px serif   getBoundingClientRect  105.4140625
//                                  measureText            105.9765625
//
// Chrome disagrees with itself by 0.5625, and this engine answers the canvas
// number down both paths -- so its layout is that much too wide for any text
// with a space beside a capital, which is most English prose, and one
// expression comparing the two readings separates the engines.
//
// Located per pair in scratch/b100/expr-space-kern.js over 56 cases: the split
// is present for a space next to A, T, V, W and Y in serif, for A, T and Y in
// sans-serif, absent for `o`, `P` and `x`, and absent entirely in Verdana. It is
// also present when the space is INTERIOR ('x Tx' splits by 0.28125), which is
// what rules out a trimming or edge effect and makes it kerning.
//
// Measured through layout and not the canvas, obviously, and in batches: one
// pair per `getBoundingClientRect` would be 300 000 forced layouts. Each family
// and face gets one container holding every candidate at once, and the widths
// come out in one pass over it.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT || 9468);
// U+0021 upward: the pair being measured always has the space as its other
// half, so the space itself is not a candidate.
const FIRST = 0x21;
const LAST = 0xff;
// The basis every advance in font_metrics.zig is stored at.
const BASIS = 100;
// Two sizes, each for what it is good for, because a LAYOUT width is snapped to
// the layout grid where a canvas width is not.
//
// WHICH pairs are real is decided at ten times the basis. At the basis itself
// `width(' X') - width(' ') - width('X')` came out -0.0078125 -- exactly 1/128,
// the grid at dpr 2 -- for 314 of sans-serif's characters, three hundred pairs
// of pure rounding sitting beside the eight real ones. Ten times the size
// divides that noise by ten and leaves the kerns where they were.
//
// WHAT each one is worth comes from the same ten-times reading, snapped to the
// grid at the basis. Both halves of that matter. Snapped, because a tenth of a
// grid step is not a grid step: the raw quotient is -3.6625 where the value is
// -469/128 = -3.6640625. From the ten-times reading and not from the basis one,
// because the basis reading carries a whole grid step of jitter -- two runs of
// it put sans-serif's space-A at -700/128 and at -701/128, since the
// single-character widths it subtracts are snapped too. A tenth of that jitter
// vanishes in the snap, so the table is reproducible.
const PROBE_SIZE = Number(process.env.SPACE_KERN_SIZE || 1000);
// Anything under this at the basis is grid noise. Two roundings are at most
// 2/128 = 0.015625 at any size, so at ten times the basis they are at most
// 0.0015625 once divided down; the smallest real kern measured is 1.75.
const NOISE = 0.05;

const FACES = [
    ['regular', ''],
    ['bold', 'bold '],
    ['italic', 'italic '],
    ['bold_italic', 'italic bold '],
];

const headed = process.argv.includes('--headed');
const arg = (name) => {
    const i = process.argv.indexOf(name);
    return i !== -1 ? process.argv[i + 1] : null;
};
const only = arg('--only')?.split(',').map((s) => s.trim()).filter(Boolean) ?? null;

// One CSS name per family table, and the first advances of each table so a
// family that no longer resolves on this host is skipped rather than written
// down with the fallback's pairs. Both taken the way dump-kerning.mjs takes
// them -- the patterns are load-bearing on font_metrics.zig's exact layout, so
// they are copied rather than re-invented.
const metrics = await fs.readFile(path.join(repo, 'src/browser/font_metrics.zig'), 'utf8');
const nameFor = new Map();
for (const m of metrics.matchAll(/^\s*\.\{ "([^"]+)", ([a-z0-9_]+) \},$/gm)) {
    if (!nameFor.has(m[2])) nameFor.set(m[2], m[1]);
}
const advancesFor = new Map();
for (const m of metrics.matchAll(/^const glyphs_([a-z0-9_]+) = \[_\]Glyph\{\n?([\s\S]{0,400})/gm)) {
    const nums = [...m[2].matchAll(/\.advance = ([0-9.eE+-]+)/g)].slice(0, 8).map((x) => Number(x[1]));
    if (nums.length) advancesFor.set(m[1], nums);
}
let families = [...nameFor.keys()].filter((f) => advancesFor.has(f)).sort();
if (only) families = families.filter((f) => only.includes(f) || only.includes(nameFor.get(f)));
if (families.length === 0) {
    console.error('no families matched --only; names look like: ' + [...nameFor.values()].slice(0, 8).join(', '));
    process.exit(1);
}

// Each candidate goes in its own block container, so a line break between two
// of them cannot fold into either one's rect, and `white-space: pre` so the
// space is rendered rather than collapsed away.
const probe = (quoted) => `(() => {
  const chr = (c) => String.fromCharCode(c);
  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;left:-9999px;top:0;width:200000px';
  document.body.appendChild(host);

  const measure = (prefix, size, texts) => {
    const holder = document.createElement('div');
    holder.style.cssText = 'font:' + prefix + size + 'px ${quoted};white-space:pre';
    const spans = [];
    for (const t of texts) {
      const line = document.createElement('div');
      const s = document.createElement('span');
      s.textContent = t;
      line.appendChild(s);
      holder.appendChild(line);
      spans.push(s);
    }
    host.appendChild(holder);
    const widths = spans.map((s) => s.getBoundingClientRect().width);
    holder.remove();
    return widths;
  };

  const kerns = (prefix, size) => {
    const singles = [' '];
    for (let c = ${FIRST}; c <= ${LAST}; c++) singles.push(chr(c));
    const adv = measure(prefix, size, singles);
    const space = adv[0];

    const after = [];   // ' X'
    const before = [];  // 'X '
    for (let c = ${FIRST}; c <= ${LAST}; c++) { after.push(' ' + chr(c)); before.push(chr(c) + ' '); }
    const wa = measure(prefix, size, after);
    const wb = measure(prefix, size, before);

    const scale = ${BASIS} / size;
    const at = {};
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const i = c - ${FIRST};
      const own = adv[i + 1];
      at['a' + c] = (wa[i] - space - own) * scale;
      at['b' + c] = (wb[i] - own - space) * scale;
    }
    // adv[0] IS the space, so this is U+0020 through U+0027 -- the first eight
    // rows of the family's glyph table, which is what the guard compares.
    return { space, adv: adv.slice(0, 8), at };
  };

  // The layout grid at dpr 2, which every reading Chrome hands back sits on.
  const snap = (v) => Math.round(v * 128) / 128;

  const face = (prefix) => {
    const big = kerns(prefix, ${PROBE_SIZE});
    const pairs = [];
    for (let c = ${FIRST}; c <= ${LAST}; c++) {
      const ka = big.at['a' + c];
      const kb = big.at['b' + c];
      if (Math.abs(ka) >= ${NOISE}) pairs.push([0x20, c, snap(ka)]);
      if (Math.abs(kb) >= ${NOISE}) pairs.push([c, 0x20, snap(kb)]);
    }
    return { space: big.space, adv: big.adv, pairs };
  };

  const out = {
${FACES.map(([k, p]) => `    ${k}: face('${p}'),`).join('\n')}
  };
  host.remove();
  return JSON.stringify(out);
})()`;

// Turns a dump into `src/browser/font_space_kerning.zig`. Split from the
// measuring pass by `--emit <json>` because measuring 182 families twice over
// takes minutes and the formatting is what gets iterated on.
const emit = (dump) => {
    let zig = `// Generated by tools/fingerprint/dump-space-kerning.mjs -- do not edit.
//
// The kerning pairs Chrome applies in LAYOUT and not in the canvas: the ones
// with a space on one side. Same 100px basis and same shape as
// \`font_kerning.zig\`, in a file of its own because the two are measured
// through different surfaces and only one of them applies to a given reading.
//
// \`dump-kerning.mjs\` measures with \`measureText\` and its range starts at
// U+0020, yet none of the 265 840 pairs it wrote has a space in it -- because
// the canvas does not kern them. Chrome's layout does:
//
//     'AVATAR To Wo' at 16px serif    getBoundingClientRect  105.4140625
//                                     measureText            105.9765625
//
// Both of those are Chrome. This engine answered the canvas number down both
// paths, so its layout was 0.5625 too wide for that string and for any text
// with a space beside a capital -- and one expression comparing the two
// readings told the engines apart.
//
// The two readings above are reproduced by the table below: the string's space
// pairs are U+0020 before 'T' and U+0020 before 'W', -225/128 each at the
// basis, and (-225 - 225) / 128 * 16 / 100 is exactly -0.5625.
const font_metrics = @import("font_metrics.zig");
const font_variants = @import("font_variants.zig");
const font_kerning = @import("font_kerning.zig");

pub const Pair = font_kerning.Pair;
pub const Table = font_kerning.Table;

`;
    const rows = [];
    for (const t of dump) {
        for (const [face, pairs] of t.faces) {
            const sorted = pairs.slice().sort((x, y) => x[0] - y[0] || x[1] - y[1]);
            const starts = [0n, 0n, 0n, 0n];
            for (const [a] of sorted) starts[a >> 6] |= 1n << BigInt(a & 63);
            zig += `const kerns_${face}_${t.family} = [_]Pair{`;
            zig += sorted.map(([a, b, k]) => `.{ .first = ${a}, .second = ${b}, .kern = ${k} }`).join(', ');
            zig += `};\n`;
            zig += `const starts_${face}_${t.family} = [4]u64{ ${starts.map((x) => x.toString()).join(', ')} };\n`;
            rows.push(`        .{ font_metrics.${t.family}.glyphs, .${face}, &kerns_${face}_${t.family}, &starts_${face}_${t.family} },`);
        }
    }
    zig += `
/// The space pairs for a family in a variant, matched the way
/// \`font_kerning.tableFor\` matches: on the identity of the family's regular
/// advance table.
///
/// A variant with no row here kerns NO space pair, and that is a reading and
/// not a gap: every family below was measured in all four faces, so a row is
/// missing exactly where Chrome kerned nothing. This used to fall back to the
/// family's regular row, which was a quiet lie for five faces -- the italic of
/// system-ui kerns ', ' by nothing where its upright kerns it by -4.88 at the
/// basis, and 'Hello, world.' at 100px came out exactly that much narrow. The
/// other four are didot bold and sinhala_sangam_mn bold and bold-italic.
///
/// A family with no row at all returns an empty table, which is the common
/// case -- Verdana kerns no space pair at all, and its 'AVATAR To Wo' is the
/// same width through both surfaces.
pub fn tableFor(family: font_metrics.Family, variant: font_variants.Variant) Table {
    const rows = [_]struct { []const font_metrics.Glyph, font_variants.Variant, []const Pair, *const [4]u64 }{
${rows.join('\n')}
    };
    for (rows) |row| {
        if (row[0].ptr == family.glyphs.ptr and row[1] == variant) {
            return .{ .pairs = row[2], .starts = row[3].* };
        }
    }
    return .{};
}
`;
    return zig;
};

const emitFrom = arg('--emit');
if (emitFrom) {
    const dump = JSON.parse(await fs.readFile(emitFrom, 'utf8'));
    const target = path.join(repo, 'src/browser/font_space_kerning.zig');
    await fs.writeFile(target, emit(dump));
    // `zig build` depends on the fmt step, so an unformatted table fails the
    // build rather than the file -- run it here, the way dump-kerning.mjs does,
    // so a regeneration lands buildable.
    await new Promise((done) => {
        spawn('zig', ['fmt', 'src/browser/font_space_kerning.zig'], { cwd: repo, stdio: 'ignore' }).on('exit', done);
    });
    const pairs = dump.reduce((n, t) => n + t.faces.reduce((m, [, p]) => m + p.length, 0), 0);
    process.stderr.write(`wrote ${target}: ${dump.filter((t) => t.faces.length).length} families with pairs, ${pairs} pairs\n`);
    process.exit(0);
}

const userDataDir = await fs.mkdtemp('/tmp/space-kern-');
const args = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--force-device-scale-factor=2',
    'about:blank',
];
if (!headed) args.unshift('--headless=new');
const chrome = spawn(CHROME, args, { stdio: 'ignore' });
await sleep(1200);
const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

const out = [];
for (const family of families) {
    const name = nameFor.get(family);
    const quoted = /^(serif|sans-serif|monospace|cursive|fantasy|system-ui|ui-[a-z]+|math|emoji|fangsong)$/.test(name)
        ? name : `\\"${name}\\"`;
    const res = await cdp.send('Runtime.evaluate',
        { expression: probe(quoted), returnByValue: true }, sessionId);
    if (!res.result || res.result.type === 'undefined') {
        process.stderr.write(`skip ${family} (${name}): probe returned nothing\n`);
        continue;
    }
    const got = JSON.parse(res.result.value);
    // The same guard dump-kerning.mjs carries, and for the same reason: a
    // family that no longer resolves on this host measures as the fallback, and
    // writing the fallback's space pairs down under its name would be a table
    // full of quiet lies. The advances come back at PROBE_SIZE, so they are
    // scaled to the basis before the comparison.
    const want = advancesFor.get(family);
    const scale = BASIS / PROBE_SIZE;
    const same = want.every((w, i) => Math.abs(w - got.regular.adv[i] * scale) < 0.02);
    if (!same) {
        process.stderr.write(`skip ${family} (${name}): advances differ from the table -- not resolving here\n`);
        continue;
    }
    const faces = [];
    for (const [key] of FACES) {
        if (got[key].pairs.length) faces.push([key, got[key].pairs]);
    }
    out.push({ family, name, faces });
    process.stderr.write(`${family} (${name}): ${faces.length ? faces.map(([f, p]) => `${f}=${p.length}`).join(' ') : 'none'}\n`);
}
cdp.ws.close();
chrome.kill();

process.stdout.write(JSON.stringify(out, null, 1) + '\n');
