// Regenerates src/browser/webapi/css/chrome_default_display.zig from the real
// Chrome on this machine: the `display` its UA stylesheet gives each HTML tag.
//
//   node tools/fingerprint/dump-default-display.mjs [--headed]
//
// `display` is the one per-tag value chrome_per_tag_values.zig deliberately
// does not store, because resolvedDisplay has to blockify a flex or grid
// parent's children and honour a cascaded `display:none` and a stored string
// expresses neither. So the defaults lived in a hand-written switch in
// CSSStyleDeclaration, and nothing had ever checked that switch against Chrome
// tag by tag. Measured with tools/fingerprint/scratch/expr-default-display.js:
// 46 of 128 tags disagreed, including <img>, <input>, <button>, <select>,
// <textarea>, <iframe>, <canvas>, <video>, <li> and every table tag.
//
// It is worth a table because the live Cloudflare challenge reads `display` on
// nine elements (tools/fingerprint/scratch/b78-cfsc-named.json), and because a
// wrong display feeds innerText, checkVisibility and the blockification rule as
// well as the computed value itself.
//
// Three kinds of answer come out, and they are kept apart rather than flattened:
//
//   * the plain default, which is the tag alone;
//   * the ones an attribute switches (`audio` is `none` until it has
//     `controls`, `dialog` until it has `open`);
//   * the ones the parent switches (`summary` is `list-item` inside `details`
//     and `block` loose; `rt` is `ruby-text` inside `ruby` and `inline` loose).
//
// Anything whose two placements disagree for a reason this does not model is
// left out of the table and named in the generated header, so a miss means
// "not measured" rather than "measured as a div".
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, goto, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9481);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_default_display.zig');
const headed = process.argv.includes('--headed');

const PAGE = 'data:text/html,' + encodeURIComponent(
    '<!doctype html><title>display</title><meta name="color-scheme" content="light">' +
    '<body><div id=probe></div>');

// Every HTML tag Chrome's UA sheet has an opinion about, plus the legacy ones
// this engine still has element types for, plus one name no sheet mentions so
// the unknown-element answer is measured rather than assumed.
const TAGS = ('a abbr address area article aside audio b base bdi bdo blockquote body br button ' +
    'canvas caption cite code col colgroup data datalist dd del details dfn dialog div dl dt em ' +
    'embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hgroup hr html i ' +
    'iframe img input ins kbd label legend li link main map mark menu meta meter nav noscript ' +
    'object ol optgroup option output p param picture pre progress q rp rt ruby s samp script ' +
    'search section select slot small source span strong style sub summary sup table tbody td ' +
    'template textarea tfoot th thead time title tr track u ul var video wbr ' +
    'marquee frameset frame dir font center big strike tt nobr acronym plaintext xmp listing ' +
    'selectedcontent lp-unknown-element').split(' ');

// The parent a tag has to sit inside for its own rule to apply, when the two
// placements come out differently.
const PARENTS = {
    summary: 'details', rt: 'ruby', rp: 'ruby', legend: 'fieldset',
    li: 'ul', dt: 'dl', dd: 'dl', option: 'select', optgroup: 'select',
    caption: 'table', tbody: 'table', thead: 'table', tfoot: 'table',
    colgroup: 'table', col: 'colgroup', tr: 'tbody', td: 'tr', th: 'tr',
    source: 'video', track: 'video', area: 'map', param: 'object',
};

// The attribute that switches a tag's display, and nothing else about it.
const ATTRS = { audio: 'controls', dialog: 'open', video: 'controls' };

const PROBE = `(() => {
  const TAGS = ${JSON.stringify(TAGS)};
  const PARENTS = ${JSON.stringify(PARENTS)};
  const ATTRS = ${JSON.stringify(ATTRS)};
  const probe = document.getElementById('probe');

  // Read through a real box: an element still detached, or inside a template,
  // has no computed style to speak of.
  const read = (build) => {
    const wrap = document.createElement('div');
    probe.appendChild(wrap);
    const el = build(wrap);
    const v = el ? getComputedStyle(el).display : null;
    wrap.remove();
    return v;
  };

  const loose = {};
  const nested = {};
  const attributed = {};
  for (const tag of TAGS) {
    loose[tag] = read((wrap) => {
      const el = document.createElement(tag);
      wrap.appendChild(el);
      return el;
    });

    const parent = PARENTS[tag];
    if (parent) {
      nested[tag] = read((wrap) => {
        const p = document.createElement(parent);
        const el = document.createElement(tag);
        p.appendChild(el);
        wrap.appendChild(p);
        return el;
      });
    }

    const attr = ATTRS[tag];
    if (attr) {
      attributed[tag] = read((wrap) => {
        const el = document.createElement(tag);
        el.setAttribute(attr, '');
        wrap.appendChild(el);
        return el;
      });
    }
  }
  return JSON.stringify({ ua: navigator.userAgent, loose, nested, attributed });
})()`;

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'lp-display-'));
const args = [
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--force-color-profile=srgb',
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

// A tag whose two placements disagree is a rule, not a default -- unless the
// nested answer is the empty string, which is Chrome declining to give the
// element a style at all rather than giving it a display. Those are dropped:
// the table would be recording an absence.
const defaults = [];
const contextual = [];
const dropped = [];
for (const tag of TAGS) {
    const loose = out.loose[tag];
    if (loose === null || loose === '') { dropped.push(`${tag} (no computed style loose)`); continue; }
    const nested = out.nested[tag];
    if (nested !== undefined && nested !== loose) {
        if (nested === '') { dropped.push(`${tag} (empty inside <${PARENTS[tag]}>)`); continue; }
        contextual.push([tag, PARENTS[tag], nested]);
    }
    defaults.push([tag, nested !== undefined && nested !== '' ? nested : loose, loose]);
}

const attributed = [];
for (const [tag, attr] of Object.entries(ATTRS)) {
    const withAttr = out.attributed[tag];
    if (withAttr === undefined || withAttr === out.loose[tag]) continue;
    attributed.push([tag, attr, withAttr]);
}

const zigStr = (s) => `"${s}"`;
const zig = `// GENERATED by tools/fingerprint/dump-default-display.mjs — do not hand-edit.
//
// Measured from ${out.ua}
// ${defaults.length} tags, ${contextual.length} of them different inside a
// particular parent, ${attributed.length} switched by an attribute.
//
// Chrome's UA stylesheet gives each tag a \`display\`, and this engine used to
// answer one of three groups hand-written into CSSStyleDeclaration. 46 of 128
// tags disagreed: <img> <input> <button> <select> <textarea> <iframe> <canvas>
// <video> <li> and every table tag among them. The live Cloudflare challenge
// reads \`display\` on nine elements, so a wrong default is read straight off
// the page -- and it also feeds innerText, checkVisibility and the flex/grid
// blockification rule.
//
// \`lookup\` answers the tag alone. A tag whose display depends on where it sits
// (\`summary\` is \`list-item\` inside <details>, \`block\` loose) or on an
// attribute (\`audio\` is \`none\` until it has \`controls\`) has its own entry, and
// the caller applies those before the plain default.
${dropped.length > 0 ? `//
// Not in the table, because Chrome gave the element no computed style there and
// an absence is not a value:
${dropped.map((d) => '//   ' + d).join('\n')}
` : '//\n// Nothing was dropped.\n'}
const std = @import("std");

/// The UA stylesheet's display for a tag, or null for a tag not measured.
pub fn lookup(tag: []const u8) ?[]const u8 {
    return defaults.get(tag);
}

/// The display a tag takes only inside a particular parent, with the parent it
/// needs. Null when the tag reads the same wherever it sits.
pub fn contextual(tag: []const u8) ?struct { parent: []const u8, display: []const u8 } {
    const row = contextual_rows.get(tag) orelse return null;
    return .{ .parent = row[0], .display = row[1] };
}

/// The display a tag takes once it carries a particular attribute, with the
/// attribute it needs.
pub fn attributed(tag: []const u8) ?struct { attribute: []const u8, display: []const u8 } {
    const row = attributed_rows.get(tag) orelse return null;
    return .{ .attribute = row[0], .display = row[1] };
}

const defaults = std.StaticStringMap([]const u8).initComptime(.{
${defaults.map(([tag, , loose]) => `    .{ ${zigStr(tag)}, ${zigStr(loose)} },`).join('\n')}
});

const contextual_rows = std.StaticStringMap([2][]const u8).initComptime(.{
${contextual.map(([tag, parent, display]) => `    .{ ${zigStr(tag)}, .{ ${zigStr(parent)}, ${zigStr(display)} } },`).join('\n')}
});

const attributed_rows = std.StaticStringMap([2][]const u8).initComptime(.{
${attributed.map(([tag, attr, display]) => `    .{ ${zigStr(tag)}, .{ ${zigStr(attr)}, ${zigStr(display)} } },`).join('\n')}
});
`;

await fs.writeFile(outPath, zig);
console.log(`${outPath}: ${defaults.length} tags, ${contextual.length} contextual, ` +
    `${attributed.length} attribute-switched, ${dropped.length} dropped`);
