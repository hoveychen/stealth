// Regenerates src/browser/webapi/css/chrome_inherited.zig from the real Chrome
// on this machine: which longhands a child takes from its parent when it
// declares nothing itself.
//
//   node tools/fingerprint/dump-css-inherited.mjs [--headed]
//
// The gap this closes was measured with tools/fingerprint/scratch/
// expr-cascade-scope.js: a rule on an *ancestor* declaring `color:rgb(1,2,3)`
// read back `rgb(0, 0, 0)` on the child, where Chrome answers the ancestor's
// value. Four of that probe's ten inherited readings agreed, and the four that
// agreed were the ones that do *not* inherit — so the cascade was being asked
// only about the element itself.
//
// There is no API that reports whether a property inherits, so it is measured
// the only way it can be: give the parent a value that is not the initial one
// and see whether the child takes it.
//
//   initial = the value on an element that declares nothing
//   the parent gets candidate values until one of them changes its own computed
//     value away from `initial` -- that is what "took" means, and it is checked
//     rather than assumed, because most candidates are invalid for most
//     properties and an invalid declaration is silently dropped
//   inherits = the child, which declares nothing, now reads the parent's value
//
// `child === parent && parent !== initial` was the whole test, and the claim
// here used to be that it cannot produce a false positive. It can, and `width`
// was one: a block-level child fills its containing block, so a parent given
// `width: 300px` has a child whose computed width reads `300px` too -- matched,
// moved off its initial, and not inherited at all. `inline-size`, the same
// property under its logical spelling, came out with it.
//
// So the test is run against two children at once. `child` is an ordinary
// block; `shrink` is `display: inline-block`, which shrink-to-fits and
// therefore cannot take a width from its parent. A name inherits only if BOTH
// took the parent's value. One that only the block child took is box-filling,
// and the generated header names those rather than dropping them silently.
//
// Measured with tools/fingerprint/scratch/expr-width-not-inherited.js: in a
// 300px parent, Chrome's block child reads `width: 300px` and its inline-block,
// floated and absolutely positioned children all read `8px`, while `color` and
// `letter-spacing` read the parent's value on every one of them.
//
// A longhand no candidate takes on is not guessed at. It is left out of the
// table and listed in the generated file's header, so the hole is auditable
// rather than silently filled with the wrong answer -- the same rule the
// initial-values dumper follows for its box-dependent names.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9477);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_inherited.zig');
const headed = process.argv.includes('--headed');

// Three bare nested divs. `probe` is the parent that gets the declaration,
// `child` declares nothing and is what the test reads, and `bare` is outside
// the pair so its values are the initial ones whatever `probe` is carrying.
const PAGE = 'data:text/html,' + encodeURIComponent(
    '<!doctype html><title>inherit</title><meta name="color-scheme" content="light">' +
    '<body><div id=bare></div>' +
    '<div id=probe><div id=child></div><div id=shrink></div></div>');

// Values to try, roughly in order of how many properties accept one. Nothing
// here has to be valid anywhere in particular -- an invalid declaration is
// dropped and the next candidate is tried -- so the list is judged by whether
// it leaves any longhand unclassified, which the generated header reports.
const CANDIDATES = [
    'red', 'rgb(1, 2, 3)', '3px', '17px', '0px', '2', '0.25', '1.5', '13',
    'none', 'auto', 'normal', 'hidden', 'visible', 'collapse', 'solid',
    'dashed', 'dotted', 'double', 'italic', 'oblique', 'bold', '700',
    'uppercase', 'lowercase', 'capitalize', 'center', 'right', 'left', 'justify',
    'nowrap', 'pre', 'break-word', 'break-all', 'anywhere', 'pointer',
    'crosshair', 'wait', 'block', 'inline', 'flex', 'grid', 'contents',
    'absolute', 'relative', 'sticky', 'fixed', 'both', 'always', 'avoid',
    'wrap', 'wrap-reverse', 'column', 'column-reverse', 'row-reverse',
    'scroll', 'clip', 'baseline', 'middle', 'sub', 'super', 'text-top',
    'separate', 'repeat-x', 'no-repeat', 'space', 'round', 'contain', 'cover',
    'border-box', 'padding-box', 'content-box', 'text', 'ellipsis',
    'currentcolor', 'transparent', 'rtl', 'isolate', 'embed', 'bidi-override',
    'vertical-rl', 'sideways-rl', 'mixed', 'upright', 'under', 'over',
    'line-through', 'overline', 'underline', 'wavy', 'disc', 'square',
    'decimal', 'upper-roman', 'inside', 'outside', 'from-font', 'grayscale',
    'antialiased', 'optimizelegibility', 'geometricprecision', 'multiply',
    'screen', 'difference', 'luminance', 'alpha', 'stretch', 'space-between',
    'space-around', 'flex-start', 'flex-end', 'self-start', 'end', 'start',
    'first', 'last', 'safe center', 'dense', 'span 2', 'stable', 'manual',
    'balance', 'infinite', 'alternate', 'forwards', 'paused', 'linear',
    'step-start', '0.5s', '250ms', '1deg', 'rotate(1deg)', 'translateX(3px)',
    'blur(1px)', 'saturate(0.5)', 'Georgia', 'local', 'fill', 'stroke',
    'crispedges', 'pixelated', 'optimizespeed', 'painted', 'all', 'strict',
    'content', 'layout', 'size', 'style', 'view-box', 'fill-box', 'stroke-box',
    'flat', 'preserve-3d', 'backwards', 'reverse',

    // A second block, added after a first run left 79 longhands unclassified.
    // These are shapes the generic keywords above cannot reach: a percentage, a
    // string, a url, an image, a shadow, a font-feature tuple, an SVG path, a
    // dashed-ident timeline name, and the one keyword each of the several
    // enumerations whose initial value the first block happened to name.
    '50%', '"x"', '"a"', '"en"', '"ENG"', 'url(#a)',
    'linear-gradient(red, blue)', '1px 1px red', 'red blue',
    '"liga" 0', '"wght" 700', 'path("M0 0")', 'inset(1px)',
    'rect(1px, 2px, 3px, 4px)', '--a', 'medium', 'thick',
    'small-caps', 'jis78', 'ordinal', 'historical-forms', 'light',
    'bottom', 'hide', 'evenodd', 'non-scaling-stroke', 'static', 'high',
    'inert', 'allow-keywords', 'compact', 'exact', 'smooth', 'trim-both',
    'dot', 'open', 'sesame', 'triangle', 'space-all', 'preserve',
    'vertical', 'visual', 'after', 'horizontal', 'read-write', 'add',
    'allow-discrete', 'clone', 'most-width', 'grid-order', 'nearest',
    'before',

    // A third block, for the seven the second one still left open.
    'subtract', 'intersect', 'exclude', 'constrained-high', 'standard',
    'no-limit', 'proximity', 'scale-down', 'consistent',
];

// A border width is pinned to 0 while the border style is `none`, so no value
// of `border-top-width` alone can move it off its initial. The auxiliary
// declaration goes on all three elements -- bare, probe *and* child -- so the
// child is equally able to show a width if the property inherits, and the test
// stays a measurement rather than a construction.
const AUX = [
    {
        match: /^border-(top|right|bottom|left|block-start|block-end|inline-start|inline-end)-width$/,
        decl: 'border-style:solid;border-block-style:solid;border-inline-style:solid',
    },
];

const PROBE = `(() => {
  const bare = document.getElementById('bare');
  const probe = document.getElementById('probe');
  const child = document.getElementById('child');
  // Shrink-to-fit, so a match here cannot be the child filling its parent.
  const shrink = document.getElementById('shrink');
  const CANDIDATES = ${JSON.stringify(CANDIDATES)};
  const AUX = ${JSON.stringify(AUX.map((a) => ({ match: a.match.source, decl: a.decl })))}
    .map((a) => ({ match: new RegExp(a.match), decl: a.decl }));

  const csBare = getComputedStyle(bare);
  const names = [];
  for (let i = 0; i < csBare.length; i++) names.push(csBare[i]);

  const inherited = [];
  const notInherited = [];
  const unclassified = [];
  const boxFilling = [];

  for (const name of names) {
    const aux = (AUX.find((a) => a.match.test(name)) || {}).decl || '';
    for (const el of [bare, probe, child]) el.setAttribute('style', aux);
    // The shrink child keeps its display through the aux reset, or it stops
    // being the control it is here to be.
    shrink.setAttribute('style', aux + ';display:inline-block');
    const initial = getComputedStyle(bare).getPropertyValue(name);
    let took = null;
    for (const candidate of CANDIDATES) {
      probe.style.setProperty(name, candidate);
      const got = getComputedStyle(probe).getPropertyValue(name);
      if (got !== initial && got !== '') { took = got; break; }
      probe.style.removeProperty(name);
    }
    if (took === null) { unclassified.push(name); continue; }
    const seenBlock = getComputedStyle(child).getPropertyValue(name) === took;
    const seenShrink = getComputedStyle(shrink).getPropertyValue(name) === took;
    if (seenBlock && seenShrink) inherited.push(name);
    else if (seenBlock) boxFilling.push(name);
    else notInherited.push(name);
  }
  for (const el of [bare, probe, child, shrink]) el.removeAttribute('style');

  return JSON.stringify({
    ua: navigator.userAgent,
    total: names.length,
    inherited, notInherited, unclassified, boxFilling,
  });
})()`;

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'lp-inherit-'));
const args = [
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`,
    '--no-first-run', '--no-default-browser-check', '--force-color-profile=srgb',
];
if (!headed) args.push('--headless=new');
const chrome = spawn(CHROME, args, { stdio: 'ignore' });

let out;
try {
    let cdp = null;
    for (let i = 0; i < 60; i++) {
        try { cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`); break; } catch { await sleep(250); }
    }
    if (!cdp) throw new Error('CDP never came up');
    const { sessionId } = await newPage(cdp);
    await goto(cdp, sessionId, PAGE);
    await sleep(400);
    out = JSON.parse(await evaluate(cdp, sessionId, PROBE));
    await cdp.close();
} finally {
    chrome.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true });
}

const wrap = (names, indent) => {
    const lines = [];
    let line = indent;
    for (const name of names) {
        if (line.length + name.length + 2 > 76) { lines.push(line); line = indent; }
        line += (line === indent ? '' : ' ') + name + ',';
    }
    if (line !== indent) lines.push(line);
    return lines.join('\n');
};

const zig = `// GENERATED by tools/fingerprint/dump-css-inherited.mjs — do not hand-edit.
//
// Measured from ${out.ua}
// ${out.inherited.length} of ${out.total} computed longhands inherit; ${out.notInherited.length} do not, ${out.unclassified.length} could not be classified.
//
// Whether a child that declares nothing takes a longhand from its parent. There
// is no API that answers this, so it is measured: the parent is given values
// until one changes its own computed value off the initial, and the child is
// then read.
//
// \`child === parent && parent !== initial\` is not enough on its own. A
// block-level child fills its containing block, so a parent given
// \`width: 300px\` has a child reading \`300px\` without inheriting anything. The
// test therefore runs against two children: an ordinary block, and an
// \`inline-block\` that shrink-to-fits and so cannot take a width from its
// parent. A name is in the table only if both took the parent's value.
${out.boxFilling.length === 0 ? '//\n// Nothing came out box-filling.\n//' : `//
// Matched on the block child alone, so box-filling rather than inherited:
${wrap(out.boxFilling, '//   ').replace(/,$/, '')}
//`}
// The unclassified names are the ones no candidate value was valid for. They
// are absent from the table rather than guessed at, so a lookup answers "does
// not inherit" for them, which is the behaviour that predates the table:
${out.unclassified.length === 0 ? '//   (none)' : wrap(out.unclassified, '//   ').replace(/,$/, '')}

const std = @import("std");

/// The longhands a child takes from its parent when it declares none itself.
pub const inherited = std.StaticStringMap(void).initComptime(.{
${out.inherited.map((n) => `    .{"${n}"},`).join('\n')}
});

/// True when \`name\` is a longhand whose value a child inherits.
pub fn inherits(name: []const u8) bool {
    return inherited.has(name);
}
`;

await fs.writeFile(outPath, zig);
console.error(`wrote ${outPath}: ${out.inherited.length} inherited, ${out.notInherited.length} not, ${out.unclassified.length} unclassified of ${out.total}`);
if (out.unclassified.length) console.error('unclassified: ' + out.unclassified.join(' '));
