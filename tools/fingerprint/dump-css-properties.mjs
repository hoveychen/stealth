// Regenerates src/browser/webapi/css/chrome_properties.zig from the real Chrome
// on this machine.
//
//   node tools/fingerprint/dump-css-properties.mjs [--headed]
//
// A CSSStyleDeclaration carries two property name lists, and fingerprinting
// scripts read both:
//
//   computed   the dash-case longhands a computed style enumerates by index.
//              `getComputedStyle(el).length` is their count and `[i]` is the
//              name at that position. Chrome's order is neither alphabetical
//              nor spec order for the whole list -- it is alphabetical over
//              unprefixed names with the -webkit- block appended -- so the
//              order is measured rather than derived.
//   aliases    every name `Object.getOwnPropertyNames` reports, which is the
//              camelCase spelling of each supported property plus the
//              shorthands and the legacy webkit aliases. Both a computed style
//              and an inline style expose all of them, even when nothing is
//              set, so this list does not depend on the element.
//   alias_set  the subset of those a declaration actually answers. It is not
//              the whole list: the nine `epub*` names are reported by
//              getOwnPropertyNames and by nothing else -- `'epubCaptionSide'
//              in style` is false, there is no descriptor for it and reading
//              it gives undefined -- so `Object.keys` is nine shorter than
//              getOwnPropertyNames. Collecting only the enumerable names, as
//              this did until B78, dropped those nine on the floor.
//
// A third list is measured here and deliberately not written out: every
// `webkit*` alias also answers under a capital W (`WebkitBoxAlign`), readable
// and `in` and carrying a descriptor, yet absent from getOwnPropertyNames and
// from Object.keys. That doubling is exact -- 151 of 151 `webkit*` names have
// it and no other name does -- so the engine derives it with a rule rather
// than a table, and the check below is what keeps the rule honest.
//
// CreepJS reconstructs both lists to decide which Chrome version it is looking
// at (tools/fingerprint/dump-creep-features.mjs reports the gap), and it is the
// single largest block of what it finds missing here.
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
const PORT = Number(process.env.PORT ?? 9473);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_properties.zig');

// A blank document: the lists must not pick up anything this page happens to
// set, and a computed style enumerates the same longhands either way.
const PAGE = 'data:text/html,<!doctype html><title>css</title><body>';

const PROBE = `(() => {
  const computedDecl = getComputedStyle(document.body);
  const inlineDecl = document.body.style;
  const indexed = [];
  for (let i = 0; i < computedDecl.length; i++) indexed.push(computedDecl[i]);
  const own = (d) => Object.getOwnPropertyNames(d).filter((k) => isNaN(+k));
  const named = (d) => Object.keys(d).filter((k) => isNaN(+k));
  // The capitalised spelling of each own name that the declaration answers
  // even though it never lists it.
  const cased = (d) => own(d)
    .map((n) => n[0].toUpperCase() + n.slice(1))
    .filter((u) => u in d);
  // Which own names answer nothing at all: listed, but not readable and with
  // no descriptor.
  const dead = (d) => own(d).filter((n) => !(n in d));
  const proto = Object.getPrototypeOf(computedDecl);
  return JSON.stringify({
    userAgent: navigator.userAgent,
    computed: indexed,
    aliases: own(computedDecl),
    inlineAliases: own(inlineDecl),
    enumerable: named(computedDecl),
    inlineEnumerable: named(inlineDecl),
    cased: cased(computedDecl),
    inlineCased: cased(inlineDecl),
    dead: dead(computedDecl),
    inlineDead: dead(inlineDecl),
    inlineLength: inlineDecl.length,
    interfaceName: proto.constructor.name,
    prototypeOwn: Object.getOwnPropertyNames(proto),
    // Chrome 150 has no CSSStyleProperties global; recorded so a later Chrome
    // that grows one shows up as a changed table rather than a silent skew.
    hasCSSStylePropertiesGlobal: typeof CSSStyleProperties !== 'undefined',
  });
})()`;

// Comment lines stay inside 80 columns, so a long measured list is folded
// rather than emitted as one unreadable line.
const wrapComment = (text) => {
    const out = [];
    let line = '//';
    for (const word of text.split(' ')) {
        if (line.length + 1 + word.length > 79) {
            out.push(line);
            line = '//';
        }
        line += ' ' + word;
    }
    if (line !== '//') out.push(line);
    return out;
};

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

// CDP_ENDPOINT points this at a Chrome we did not spawn -- the Linux container
// from linux-chrome.mjs, whose table is the one that belongs in the tree now
// that the engine claims Linux. Without it, the only measurable Chrome is the
// macOS one on this machine.
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;

const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cssprops-'));
const proc = ENDPOINT ? null : spawn(CHROME, [
    ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
    '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
], { stdio: ['ignore', 'pipe', 'pipe'] });
const ws = proc ? createWriteStream(path.join(os.tmpdir(), 'cssprops-chrome.log')) : null;
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

    // Both declarations answer the same name sets. If they ever stop doing so
    // the model below (one list, shared) is wrong, so check rather than assume.
    for (const [what, x, y] of [
        ['own', measured.aliases, measured.inlineAliases],
        ['enumerable', measured.enumerable, measured.inlineEnumerable],
        ['cased', measured.cased, measured.inlineCased],
        ['unanswered', measured.dead, measured.inlineDead],
    ]) {
        if (x.join('\0') !== y.join('\0')) {
            throw new Error(`computed and inline declarations expose different ${what} name sets; the shared list is no longer valid`);
        }
    }
    if (measured.inlineLength !== 0) {
        throw new Error(`an untouched inline style enumerated ${measured.inlineLength} indexed properties, expected 0`);
    }
    // Every computed longhand should have a camelCase counterpart the
    // declaration answers, otherwise a name reachable by index is unreachable
    // by property. Checked against the answered names rather than the listed
    // ones: being listed is not the same as being reachable here.
    const camel = (s) => (s.startsWith('-') ? s.slice(1) : s).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const answered = new Set(measured.enumerable);
    const orphans = measured.computed.filter((p) => !answered.has(camel(p)));
    if (orphans.length) {
        throw new Error(`computed longhands with no answered alias counterpart: ${orphans.join(', ')}`);
    }
    // The names that are listed and nothing else have to be exactly the ones
    // Object.keys drops, or `answered` above is measuring something else.
    const listedOnly = measured.aliases.filter((n) => !answered.has(n));
    if (listedOnly.join(' ') !== measured.dead.join(' ')) {
        throw new Error(`listed-but-not-enumerable (${listedOnly.join(', ')}) disagrees with listed-but-unreadable (${measured.dead.join(', ')})`);
    }
    // The rule the engine implements instead of a table: a capital-W spelling
    // exists for every webkit alias, for nothing else, and is never listed.
    const expectedCased = measured.enumerable
        .filter((n) => n.startsWith('webkit'))
        .map((n) => n[0].toUpperCase() + n.slice(1));
    if ([...measured.cased].sort().join(' ') !== [...expectedCased].sort().join(' ')) {
        throw new Error(
            'the capital-W spellings are no longer exactly the webkit aliases: ' +
            `measured ${measured.cased.length}, derived ${expectedCased.length}. ` +
            'CSSStyleDeclaration.casedAliasSpelling derives them from this rule, ' +
            'so either that or this check has to change.');
    }
    const casedListed = measured.cased.filter((n) => measured.aliases.includes(n));
    if (casedListed.length) {
        throw new Error(`capital-W spellings turned up in getOwnPropertyNames: ${casedListed.join(', ')}`);
    }

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-properties.mjs — do not hand-edit.',
        '//',
        `// Measured from ${measured.userAgent}`,
        `// ${measured.computed.length} computed longhands, ${measured.aliases.length} alias names, ${measured.enumerable.length} of them answered.`,
        '//',
        '// `computed` is what a computed style enumerates by index, in Chrome\'s own',
        '// order: alphabetical over the unprefixed names, then the -webkit- block.',
        `// getComputedStyle(el).length is ${measured.computed.length} and [i] is computed[i].`,
        '//',
        '// `aliases` is every name Object.getOwnPropertyNames reports. It covers the',
        '// shorthands and legacy webkit spellings that are not computed longhands, so',
        '// it is the longer list, and an untouched inline style exposes all of it',
        '// while enumerating no indices at all.',
        '//',
        `// ${listedOnly.length} of those names are listed and nothing else:`,
        ...wrapComment(listedOnly.join(', ') + '.'),
        '// Chrome reports them from getOwnPropertyNames while `in` says no, there is',
        '// no descriptor and reading gives undefined, which is why Object.keys is',
        '// that much shorter. They are absent from `alias_set` on purpose, and any',
        '// consumer that turns `aliases` into CSS property names has to skip them --',
        '// the dashed `-epub-*` spellings they stand for are real properties in',
        '// Chrome, but nothing in this engine parses one yet.',
        '//',
        `// Every one of the ${measured.cased.length} webkit aliases also answers under a capital W`,
        '// (`WebkitBoxAlign`): readable, `in`, carrying a descriptor -- and listed by',
        '// neither getOwnPropertyNames nor Object.keys. No other name does. The engine',
        '// derives that spelling instead of storing it, and the generator asserts the',
        '// rule against Chrome every time this file is rebuilt.',
        '//',
        `// Chrome exposes both on ${measured.interfaceName}, whose prototype owns only:`,
        `//   ${measured.prototypeOwn.join(', ')}`,
        `// and has no CSSStyleProperties global (measured: ${measured.hasCSSStylePropertiesGlobal}).`,
        '',
        'const std = @import("std");',
        '',
        'pub const computed = [_][]const u8{',
        ...measured.computed.map((p) => `    ${zigString(p)},`),
        '};',
        '',
        'pub const aliases = [_][]const u8{',
        ...measured.aliases.map((p) => `    ${zigString(p)},`),
        '};',
        '',
        '// The names a declaration actually answers -- `aliases` minus the ones it',
        '// only lists. Whether a name is in here decides whether an unset property',
        '// reads as "" or as undefined, so the answer has to be exact rather than',
        '// pattern-matched: Chrome answers "" to style.webkitBorderRadius and',
        '// undefined to style.webkitNotSet, and no rule about the `webkit` prefix',
        '// separates those two.',
        'pub const alias_set = std.StaticStringMap(void).initComptime(.{',
        ...measured.enumerable.map((p) => `    .{ ${zigString(p)}, {} },`),
        '});',
        '',
    ];
    await fs.writeFile(outPath, lines.join('\n'));
    console.log(`wrote ${path.relative(repo, outPath)} — ${measured.computed.length} computed, ${measured.aliases.length} aliases (${measured.enumerable.length} answered, ${listedOnly.length} listed only), ${measured.cased.length} capital-W spellings derived`);
    console.log(`  interface ${measured.interfaceName}, prototype owns ${measured.prototypeOwn.length}, CSSStyleProperties global: ${measured.hasCSSStylePropertiesGlobal}`);
} finally {
    try { ws?.close(); } catch { /* already closed */ }
    proc?.kill('SIGKILL');
    await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
}
