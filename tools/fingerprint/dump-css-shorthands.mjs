// Regenerates src/browser/webapi/css/chrome_shorthands.zig from the real Chrome
// on this machine.
//
//   node tools/fingerprint/dump-css-shorthands.mjs [--headed]
//
// Chrome does not keep a shorthand in a declaration. It expands it into its
// longhands and stores those: `border: 1px solid red` is seventeen entries, not
// one, so `style.length` is 17, `item(2)` is `border-top-width`, and both
// `getPropertyValue('border')` and `cssText` are *reconstructed* from the
// longhands rather than echoed back. Three things have to be measured for that
// to be reproducible, and none of them can be read out of a spec:
//
//   1. The longhand list *and its order*, since the order is what `item(i)`
//      answers. Measured by setting the shorthand to `inherit`, which parses for
//      every property there is, so the same probe reaches all of them.
//   2. What an unmentioned longhand is left holding -- the `fillers` below.
//      Blink is not consistent here and the inconsistency is visible:
//      `text-decoration: red` leaves the other three reading the literal
//      `initial`, where `border-top: red` leaves `medium` and `none`, the
//      initial values spelled out. Same shape of shorthand, different answer.
//   3. How the value's components are distributed. `border: 1px solid red`,
//      `solid red 1px` and `red 1px solid` all land the same way, so the
//      distribution is by what each longhand accepts rather than by position --
//      which is why `value_classes` is measured too, and why the acceptance test
//      the engine will run is simulated here against every measured row before
//      a shorthand is called modelled at all.
//
// A fourth thing, for `background` and the rest of the layered ones: a comma is
// a layer boundary, and inside a layer the components are not a flat run. One
// position fills *two* longhands out of one to four tokens whose order carries
// meaning (`top right` and `right top` both land x=right y=top, and `10px left`
// does not parse at all), a `/` introduces a size and may only sit straight
// after the position, one box token fills the origin *and* the clip, and the
// colour belongs to the whole value rather than to a layer -- which is why
// `background: red, blue` does not parse and `url(a), red` does. That shape is
// `.layers`, and every part of it is derived from the rows below.
//
// A shorthand no model reproduces is emitted as `.unmodelled` and the engine
// keeps it whole, which is the safe direction: a page reading `style.length`
// sees 1 instead of 9, where a wrong expansion would answer nine wrong values.
// A model is also allowed to *decline* a single value rather than model it --
// `background: repeat no-repeat` stores `repeat-x`, which is the repeat
// longhand's own canonicalisation and not this table's business -- and the
// declines are printed on every run rather than swallowed.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ??
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9493);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_shorthands.zig');

// Same pin as the keyword and value-case tables.
const MDN_DATA = '2.24.0';

// `revert-rule` joined the list in Chrome 152 and behaves like the rest:
// `border: revert-rule` reaches all seventeen longhands in the CSS-wide
// per-side order, `grid-template-areas` takes it though it takes no bare
// identifier otherwise, and CSS.supports answers it exactly as it answers
// `inherit`. Leaving it out cost real fidelity rather than one row: the
// shorthand table read its per-side order as a *second* longhand order for
// `border` and demoted border and twelve of its relatives to `.unmodelled`,
// which answers style.length 1 where Chrome answers 17.
const CSS_WIDE = ['inherit', 'initial', 'unset', 'revert', 'revert-layer', 'revert-rule'];

// One representative token per value type a longhand can take. The engine
// classifies a component by shape and looks the class up here, so this list is
// the whole vocabulary of the acceptance test -- a component whose class is not
// in it can never be placed, and its shorthand is demoted rather than guessed
// at.
const CLASS_TOKENS = {
    length: '1px',
    percent: '1%',
    number: '2',
    angle: '45deg',
    time: '1s',
    url: 'url(a)',
    string: '"str"',
    identifier: 'MyIdentXyz',
    colour: '#abc',
    function: 'rgb(1, 2, 3)',
    gradient: 'linear-gradient(red, blue)',
    image: 'image-set("a" 1x)',
};

// A function token's class comes from its *name*, not from the fact that it is
// a function: `background-image` takes `linear-gradient()` and not `rgb()`,
// `background-color` the other way round, and a value class that cannot tell
// them apart puts a gradient in the colour. A name this list does not know has
// no class at all, so a value carrying one is declined rather than guessed at.
const FUNCTION_CLASS = (name) => {
    const lower = name.toLowerCase();
    if (/-gradient$/.test(lower)) return 'gradient';
    if (lower === 'image-set' || lower === '-webkit-image-set') return 'image';
    return [
        'rgb', 'rgba', 'hsl', 'hsla', 'hwb', 'lab', 'lch', 'oklab', 'oklch',
        'color', 'color-mix', 'light-dark',
    ].includes(lower) ? 'function' : null;
};

// Values offered to every shorthand. Only the ones that parse are recorded, so
// this is a net rather than a mapping: no per-shorthand knowledge is encoded.
// Each has to be reproduced by the derived model or the shorthand is demoted,
// so widening this list can only make the tables more honest.
const VALUES = [
    ...CSS_WIDE,
    '1px', '2px', '1%', '2', '1.5', '0',
    'red', 'currentColor', 'blue',
    'solid', 'dashed', 'none', 'auto', 'normal', 'hidden', 'scroll',
    'url(a)', '1s', '2s', '45deg', 'MyIdent', '"str"', '#abc',
    'round', 'bevel', 'notch', 'squircle', 'scoop',
    '1px 2px', '1px 2px 3px', '1px 2px 3px 4px',
    'red blue', 'red blue green', 'red blue green yellow',
    'solid dashed', 'solid dashed dotted', 'solid dashed dotted double',
    'round bevel', 'round bevel notch', 'round bevel notch scoop',
    'auto auto', 'none none', 'normal normal', 'hidden scroll',
    '1px solid red', 'solid red 1px', 'red 1px solid',
    '2px dashed blue', 'blue 2px dashed',
    '1px / 2px', '1px 2px / 3px 4px', 'a / b', '1 / 2 / 3 / 4', '2 / 3',
    '1s 2s', '1s linear', 'linear 1s', 'MyIdent 1s',
    'row wrap', 'wrap row', '12px serif', 'italic 12px serif',
    'weight', 'style', 'small-caps', 'weight style', 'style weight',
    'inside url(a) disc', 'disc inside', 'over right', 'filled dot',
    'underline wavy red', 'wavy underline', 'inline size', 'size inline',
    'stable both-edges', 'trim-both cap alphabetic',
    'always', 'avoid', 'page', 'left', 'right', 'top', 'bottom', 'center',
    'block', 'inline', 'both', 'content-box', 'border-box', 'padding-box',
    'repeat-x', 'no-repeat', 'fixed', 'ease', 'infinite', 'alternate',
    'forwards', 'running', 'wavy', 'underline', 'contain', 'cover',
    'flat', 'preserve-3d', 'add', 'exclude', 'economy', 'nowrap', 'balance',
    // The layered shorthands. A comma is a layer boundary, a `/` introduces a
    // size, and a position takes up to four tokens whose order carries meaning
    // -- so these have to be offered as well, or the layer model is checked
    // against nothing that exercises it.
    'url(a) no-repeat', 'no-repeat url(a)', 'red url(a)', 'url(a) red',
    'red url(a) no-repeat', 'url(a) no-repeat center / cover',
    'url(a) center / cover no-repeat fixed padding-box border-box red',
    'linear-gradient(red, blue)', 'linear-gradient(red, blue) no-repeat',
    'top right', 'right top', 'left top', 'top left', 'center center',
    'center top', 'top center', '10px center', 'center 10px', '50% 50%',
    'left 10px', '10px left', 'left center', 'center left',
    'left 10px top 20px', 'right 10px bottom 20px', 'left top 20px',
    'left 10px top', 'top 20px left 10px', 'center top 10px', 'top 10px center',
    'left 10px center', 'center 10px top', 'left center 10px',
    'center center 10px', 'left 10px right 20px', 'left top 10px 20px',
    'center / cover', 'center / contain', '/ cover', '2px / auto',
    'left top / 10px 20px', 'left 10px top 20px / cover', 'center / 10px',
    'url(a) / 20px', 'no-repeat / 20px', '2px no-repeat / 20px',
    'center no-repeat / cover', 'url(a) 0/0',
    'padding-box border-box', 'border-box padding-box', 'content-box content-box',
    'border-box content-box', 'text border-box', 'padding-box text',
    'text', 'no-clip', 'border-box no-clip', 'content-box no-clip',
    'left 10px no-repeat', 'left top no-repeat', 'no-repeat left 10px top 20px',
    'repeat', 'repeat-y', 'space', 'local', 'alpha', 'luminance',
    'match-source', 'intersect', 'subtract', 'none red', 'red 2px',
    'repeat no-repeat', 'no-repeat repeat', 'space round',
    'red, blue', 'url(a), url(b)', 'url(a), url(b) blue', 'url(a) blue, url(b)',
    'url(a), red', 'url(a), url(b), url(c)', 'url(a), url(b), url(c) red',
    'no-repeat, repeat-x', 'none, none', '10px 20px, 30px',
    'padding-box, border-box', 'padding-box border-box, content-box',
    'url(a) center / cover, url(b) left top / contain',
    'url(a) no-repeat, url(b) fixed, url(c) padding-box',
    'url(a) fixed, url(b) local', 'repeat no-repeat, space round',
];

const PAGE = 'data:text/html,<!doctype html><title>shorthands</title><body>';

const KIND_NOTES = {
    alias: 'one longhand, which takes the value whole.',
    box4: 'the 1/2/3/4-value box rule (`margin`).',
    box2: 'the 1/2-value rule (`gap`, `overflow`).',
    components: 'each component goes to the first longhand of the group that accepts it,\n' +
        '//                     and the group repeats -- which is how `border` reaches all four\n' +
        '//                     sides. Order does not matter: `1px solid red`, `solid red 1px`\n' +
        '//                     and `red 1px solid` all land identically, measured.',
    presets: 'a lookup over the whole value space, used where the keyword table says a\n' +
        '//                     single keyword is all a page can write (`white-space`).',
    corners: 'two box lists split by a `/`, one of horizontal radii and one of\n' +
        '//                     vertical, over four corner longhands that each hold a *pair*\n' +
        '//                     (`border-radius`).',
    layers: 'a comma-separated list of layers, each with a position filling two\n' +
        '//                     longhands, a size only a `/` introduces, and slots shared by the\n' +
        '//                     whole value that only the last layer may write (`background`).',
    unmodelled: 'no model reproduced every reading; the engine keeps the shorthand whole.',
};

const zigString = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
// zig fmt writes an empty and a one-element list without the inner spaces, and
// the generated file has to come out of here already formatted.
const zigSeq = (parts) => parts.length === 0
    ? '&.{}'
    : parts.length === 1
        ? `&.{${parts[0]}}`
        : `&.{ ${parts.join(', ')} }`;
const zigList = (items) => zigSeq(items.map(zigString));
// Comment prose, wrapped the way the rest of these files are.
const wrap = (text) => {
    const out = [];
    for (const word of text.split(' ')) {
        if (out.length && (out[out.length - 1] + ' ' + word).length <= 76) {
            out[out.length - 1] += ' ' + word;
        } else out.push('// ' + word);
    }
    return out;
};

// Every name worth offering to Chrome. A declaration exposes most shorthands
// only under their camelCase JS name, so `aliases` on its own misses
// `border-color` and `grid-area`: kebab them back. mdn-data widens the pool
// again, and a name Chrome does not know simply fails to parse and drops out.
async function candidateNames() {
    const source = await fs.readFile(
        path.join(repo, 'src/browser/webapi/css/chrome_properties.zig'), 'utf8');
    const list = (name) => {
        const start = source.indexOf(`pub const ${name} = [_][]const u8{`);
        if (start < 0) throw new Error(`chrome_properties.zig has no ${name} table`);
        const end = source.indexOf('\n};', start);
        return [...source.slice(start, end).matchAll(/"([^"]+)"/g)].map((m) => m[1]);
    };
    const kebab = (n) => {
        const dashed = n.replace(/([A-Z])/g, (m) => '-' + m.toLowerCase());
        return /^(webkit|epub)/.test(dashed) ? '-' + dashed : dashed;
    };
    const res = await fetch(`https://unpkg.com/mdn-data@${MDN_DATA}/css/properties.json`);
    if (!res.ok) throw new Error(`mdn-data properties.json: HTTP ${res.status}`);
    const aliases = list('aliases');
    return [...new Set([
        ...list('computed'), ...aliases, ...aliases.map(kebab),
        ...Object.keys(await res.json()),
    ])].filter((n) => !/[A-Z]/.test(n)).sort();
}

const PROBE = (names, values, classTokens, tokens, extra) => `(() => {
  const el = document.createElement('div');
  document.body.appendChild(el);
  const snap = () => {
    const s = el.style;
    const items = [];
    for (let i = 0; i < s.length; i++) items.push(s.item(i));
    return { items: items, v: items.map((p) => s.getPropertyValue(p)) };
  };
  const set = (prop, value) => {
    el.setAttribute('style', '');
    el.style.setProperty(prop, value);
    return el.style.length === 0 ? null : snap();
  };

  // \`inherit\` parses for every property there is, so one pass over the whole
  // candidate pool finds every shorthand and its longhand order at once.
  const expansion = {};
  for (const name of ${JSON.stringify(names)}) {
    const got = set(name, 'inherit');
    if (!got) continue;
    if (got.items.length === 1 && got.items[0] === name) continue;
    expansion[name] = got.items;
  }

  // What each longhand reached this way accepts, and -- just as important --
  // what it *stores* for it: \`margin: 0\` reads back \`0px\` and
  // \`border-color: #abc\` reads back \`rgb(170, 187, 204)\`, so a written token
  // cannot be compared against a stored value without this.
  const longhands = [...new Set(Object.values(expansion).flat())].sort();
  const own = ${JSON.stringify(extra)};
  const canon = {};
  for (const lh of longhands) {
    const seen = {};
    // Its own keyword list on top of the shared battery, so which identifiers
    // a longhand takes is measured rather than read off the keyword table:
    // background-clip is listed as taking border-area and does not store it.
    for (const token of ${JSON.stringify(tokens)}.concat(own[lh] ?? [])) {
      if (set(lh, token)) seen[token] = el.style.getPropertyValue(lh);
    }
    canon[lh] = seen;
  }
  const classes = {};
  for (const lh of longhands) {
    classes[lh] = Object.entries(${JSON.stringify(classTokens)})
      .filter(([, token]) => canon[lh][token] !== undefined)
      .map(([cls]) => cls);
  }

  // A shorthand's own keyword list on top of the shared battery, so a
  // keyword-only shorthand (\`white-space\`) is measured over its whole value
  // space rather than over whichever generic tokens happened to parse.
  const extra = own;
  const rows = {};
  // The values that did *not* parse matter as much as the ones that did: a
  // model that places one is answering longhands for a declaration Chrome threw
  // away.
  const rejected = {};
  for (const name of Object.keys(expansion)) {
    const got = {};
    rejected[name] = [];
    for (const value of ${JSON.stringify(values)}.concat(extra[name] ?? [])) {
      const snapped = set(name, value);
      if (!snapped) { rejected[name].push(value); continue; }
      got[value] = {
        items: snapped.items,
        v: snapped.v,
        cssText: el.style.cssText,
        read: el.style.getPropertyValue(name),
      };
    }
    rows[name] = got;
  }

  return JSON.stringify({ userAgent: navigator.userAgent, expansion, classes, canon, rows, rejected });
})()`;

// --- derivation -----------------------------------------------------------

// Split a value the way the engine will: on top-level whitespace, keeping a
// parenthesised or quoted run whole, and with `/` its own component.
function components(value) {
    const out = [];
    let depth = 0, quote = null, cur = '';
    const flush = () => { if (cur) out.push(cur); cur = ''; };
    for (const ch of value) {
        if (quote) {
            cur += ch;
            if (ch === quote) quote = null;
            continue;
        }
        if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
        if (ch === '(') depth++;
        if (ch === ')') depth--;
        if (depth === 0 && /\s/.test(ch)) { flush(); continue; }
        if (depth === 0 && ch === '/') { flush(); out.push('/'); continue; }
        cur += ch;
    }
    flush();
    return out;
}

// The engine's own classifier, by shape alone. It has to agree with the
// measured `classes` for the acceptance test to mean anything, and the
// simulation below is what checks that it does.
//
// A token can be in more than one class, and one of them matters: a unitless
// zero is a `<length>` as well as a `<number>`, which is why `border-top: 0`
// reaches the width and `border-top: 2` parses at all.
function classify(token) {
    if (/^"/.test(token) || /^'/.test(token)) return ['string'];
    if (/^#[0-9a-fA-F]+$/.test(token)) return ['colour'];
    if (/^url\(/i.test(token)) return ['url'];
    if (/\(.*\)$/.test(token)) {
        const cls = FUNCTION_CLASS(token.slice(0, token.indexOf('(')));
        return cls ? [cls] : [];
    }
    if (/^[+-]?(\d+\.?\d*|\.\d+)%$/.test(token)) return ['percent'];
    if (/^[+-]?(\d+\.?\d*|\.\d+)(deg|grad|rad|turn)$/i.test(token)) return ['angle'];
    if (/^[+-]?(\d+\.?\d*|\.\d+)(s|ms)$/i.test(token)) return ['time'];
    if (/^[+-]?(\d+\.?\d*|\.\d+)[a-zA-Z]+$/.test(token)) return ['length'];
    if (/^[+-]?0*\.?0*$/.test(token)) return ['length', 'number'];
    if (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(token)) return ['number'];
    if (/^[a-zA-Z_-][a-zA-Z0-9_-]*$/.test(token)) return ['identifier'];
    return [];
}

const BOX = {
    box4: (t) => t.length === 1 ? [t[0], t[0], t[0], t[0]]
        : t.length === 2 ? [t[0], t[1], t[0], t[1]]
            : t.length === 3 ? [t[0], t[1], t[2], t[1]]
                : t.length === 4 ? t : null,
    box2: (t) => t.length === 1 ? [t[0], t[0]] : t.length === 2 ? t : null,
};

const sameValue = (a, b) => a.toLowerCase() === b.toLowerCase();

// Whichever value a slot holds in a row that never mentioned it. Forced rather
// than guessed: a slot holding something the written value does not contain was
// filled in, so that *is* the filler, and two rows disagreeing means no single
// filler exists and the shorthand is not this shape.
function fillers(rows, width, longhands, canon) {
    const out = new Array(width).fill(null);
    for (const [value, row] of rows) {
        const toks = components(value);
        for (let i = 0; i < width; i++) {
            const stored = (t) => canon[longhands[i]]?.[t] ?? t;
            if (toks.some((t) => sameValue(stored(t), row.v[i]))) continue;
            if (out[i] === null) { out[i] = row.v[i]; continue; }
            if (!sameValue(out[i], row.v[i])) return null;
        }
    }
    // A slot every row mentioned has no measured filler; the initial value is
    // the only defensible answer and `initial` is how Blink spells that.
    return out.map((v) => v ?? 'initial');
}

// The engine's expansion, run here against the measured acceptance so a model
// is only kept when it reproduces what Chrome actually did.
function expand(kind, value, longhands, fill, group, groups, blocked, classes, keywords, canon, used) {
    const toks = components(value);
    const stored = (i, t) => canon[longhands[i]]?.[t] ?? t;
    if (toks.length === 1 && CSS_WIDE.includes(toks[0].toLowerCase())) {
        return longhands.map(() => toks[0].toLowerCase());
    }
    if (kind === 'alias') return [stored(0, value)];
    if (kind === 'box4' || kind === 'box2') {
        const mapped = BOX[kind](toks);
        if (!mapped || mapped.length !== longhands.length) return null;
        return mapped.map((t, i) => stored(i, t));
    }
    if (kind !== 'components') return null;
    const accepts = (lh, token) => {
        const cls = classify(token);
        if (cls.includes('identifier')) {
            const known = keywords[lh];
            if (known && known.includes(token.toLowerCase())) return true;
        }
        return cls.some((c) => (classes[lh] ?? []).includes(c));
    };
    // Which component slot a longhand belongs to. Two layouts, both measured:
    // `rule` repeats the group (width, style, colour, width, style, colour)
    // where `border` blocks it (four widths, four styles, four colours).
    const slotOf = (i) => blocked ? Math.floor(i / groups) : i % group;
    const representative = (slot) => longhands[blocked ? slot * groups : slot];
    const slots = new Array(group).fill(null);
    for (const token of toks) {
        let placed = false;
        for (let i = 0; i < group; i++) {
            if (slots[i] !== null) continue;
            if (!accepts(representative(i), token)) continue;
            slots[i] = token;
            used?.add(i);
            placed = true;
            break;
        }
        if (!placed) return null;
    }
    const out = [];
    for (let i = 0; i < longhands.length; i++) {
        const token = i < group * groups ? slots[slotOf(i)] : null;
        out.push(token === null ? fill[i] : stored(i, token));
    }
    return out;
}

// The shortest box form Chrome writes back: `margin: 1px 1px 1px 1px` answers
// `1px`, and `1px 2px 3px 2px` answers `1px 2px 3px`.
function boxForm(v) {
    if (v.length === 2) return sameValue(v[0], v[1]) ? [v[0]] : v;
    if (!sameValue(v[1], v[3])) return v;
    if (!sameValue(v[0], v[2])) return v.slice(0, 3);
    return sameValue(v[0], v[1]) ? [v[0]] : v.slice(0, 2);
}

// Whether the reconstruction rule reproduces `getPropertyValue(shorthand)` for
// every measured row, and for `.components` what it has to drop to do it.
//
// Dropping is the part no spec states plainly: `text-decoration: 1px solid red`
// answers `1px red`, because `solid` is text-decoration-style's initial value
// and Blink leaves an initial component out. Which value that is per slot is
// forced by the readings rather than assumed, and a slot two rows disagree
// about means the rule does not hold here.
function serialisation(name, chosen, longhands, plain) {
    const { kind, group, groups, blocked } = chosen;
    const at = (v, slot) => v[blocked ? slot * groups : slot];
    if (kind === 'alias') {
        // Reading back through the old name is its own mapping, and not the
        // inverse of `translate`: `page-break-after` answers `always` for a
        // stored `page`, and the -webkit- column spellings answer nothing at
        // all for values they cannot express.
        const reads = new Map();
        for (const [, r] of plain) {
            if (sameValue(r.read, r.v[0])) continue;
            const had = reads.get(r.v[0].toLowerCase());
            if (had !== undefined && had !== r.read) {
                return `reads a stored ${JSON.stringify(r.v[0])} as both ` +
                    `${JSON.stringify(had)} and ${JSON.stringify(r.read)}`;
            }
            reads.set(r.v[0].toLowerCase(), r.read);
        }
        chosen.reads = [...reads];
        return null;
    }
    if (kind === 'presets') {
        chosen.presets = chosen.presets.map(([v, vec]) => {
            const row = plain.find(([w]) => sameValue(w, v));
            return [v, vec, row[1].read];
        });
        return null;
    }
    if (kind === 'box4' || kind === 'box2') {
        const bad = plain.find(([, r]) => !sameValue(r.read, boxForm(r.v).join(' ')));
        return bad ? `serialises ${JSON.stringify(bad[1].read)} where the box form is ` +
            JSON.stringify(boxForm(bad[1].v).join(' ')) : null;
    }
    // A slot is dropped at more than one value: `text-decoration`'s colour is
    // left out both when it holds the literal `initial` and when it holds
    // `currentcolor`, its initial value spelled out, so this is a set per slot
    // rather than one value.
    const omit = Array.from({ length: group }, () => new Set());
    for (const [, r] of plain) {
        const shown = components(r.read);
        for (let s = 0; s < group; s++) {
            const value = at(r.v, s);
            if (components(value).every((t) => shown.includes(t))) continue;
            omit[s].add(value.toLowerCase());
        }
    }
    const keptOf = (r, order) => order
        .filter((s) => !omit[s].has(at(r.v, s).toLowerCase()))
        .map((s) => at(r.v, s));
    // What the shorthand answers once every component has been dropped, which
    // is not the same as every longhand holding its filler: `text-decoration:
    // currentColor` stores a colour and still answers `none`, because
    // `currentcolor` is one of the values that slot is dropped at. Taken from
    // the rows that reach it rather than reasoned about.
    let empty = null;
    const check = (order) => {
        for (const [value, r] of plain) {
            const kept = keptOf(r, order);
            if (kept.length === 0 && empty === null) empty = r.read;
            const want = kept.length ? kept.join(' ') : (empty ?? r.read);
            if (!sameValue(r.read, want)) {
                return `serialises ${JSON.stringify(r.read)} for ${JSON.stringify(value)}` +
                    ` where the kept components are ${JSON.stringify(want)}`;
            }
        }
        return null;
    };

    // The reading whose components all dropped also says what cssText writes
    // instead when the shorthand cannot be written at all.
    const record = () => {
        chosen.omit = omit.map((set) => [...set].sort());
        chosen.empty = empty;
        if (empty === '') {
            const row = plain.find(([, r]) => r.read === '');
            chosen.fallback = [...row[1].cssText.matchAll(/(^|; )([-a-z]+):/g)].map((m) => m[2]);
        }
    };

    const identity = [...Array(group).keys()];
    let failure = check(identity);
    if (!failure) {
        record();
        chosen.order = [];
        return null;
    }
    empty = null;
    // The order components come back in is not always the order the longhands
    // are stored in: `transition` stores its behaviour first and writes its
    // property first. No single reading shows the whole order -- each shows two
    // components at most -- so the pairs are collected across every row and
    // sorted into one order.
    const after = Array.from({ length: group }, () => new Set());
    for (const [, r] of plain) {
        const shown = components(r.read);
        const seen = identity
            .filter((s) => !omit[s].has(at(r.v, s).toLowerCase()))
            .map((s) => [s, shown.indexOf(components(at(r.v, s))[0])])
            .filter(([, at_]) => at_ >= 0)
            .sort((a, b) => a[1] - b[1])
            .map(([s]) => s);
        for (let i = 1; i < seen.length; i++) after[seen[i]].add(seen[i - 1]);
    }
    const derived = [];
    while (derived.length < group) {
        const next = identity.find((s) => !derived.includes(s) &&
            [...after[s]].every((p) => derived.includes(p)));
        if (next === undefined) break;   // a cycle: no one order explains it
        derived.push(next);
    }
    if (derived.length !== group) return failure;
    failure = check(derived);
    if (failure) return failure;
    record();
    chosen.order = derived;
    return null;
}

// --- the corner grammar ---------------------------------------------------

// `border-radius` is the one four-value box shorthand carrying a `/`, and the
// `/` is what makes it its own kind: two box lists, one of horizontal radii and
// one of vertical, over four corner longhands that each hold a *pair*.
//
// That pair is also why `fillers` cannot see this shape at all. It asks whether
// a slot's stored value is one of the value's own tokens, and a corner holding
// `1px 3px` is not -- so a shorthand this shape is demoted for "no single
// filler explains every row" before any distribution rule gets its turn. The
// fillers here are derived rather than measured, which is honest for the same
// reason `.layers` derives its own: every value Chrome accepts reaches all four
// corners, so no row leaves one holding a filler and there is nothing to
// measure.

// What Chrome stores for `name: value`, or null when the value does not fit.
function cornersExpand(value, longhands, canon, legacy, takes) {
    const sides = [[], []];
    let half = 0;
    for (const token of components(value)) {
        if (token === '/') {
            // A second `/`, and one with nothing before it, are both declines.
            if (half === 1 || sides[0].length === 0) return null;
            half = 1;
            continue;
        }
        // A radius is a length or a percentage and nothing else, so `auto`,
        // `none` and a bare number are declines rather than four invented
        // corners. All four longhands take the same classes, measured, which is
        // why the first stands for the lot.
        if (!takes(longhands[0], token)) return null;
        if (sides[half].length === 4) return null;
        sides[half].push(token);
    }
    // A `/` with nothing after it is a decline too.
    if (!sides[0].length || (half === 1 && !sides[1].length)) return null;
    // The legacy WebKit spelling reads *exactly* two components as
    // horizontal-then-vertical rather than top-left-then-top-right.
    if (half === 0 && legacy && sides[0].length === 2) {
        sides[1] = [sides[0][1]];
        sides[0] = [sides[0][0]];
        half = 1;
    }
    const across = BOX.box4(sides[0]);
    const down = half === 0 ? across : BOX.box4(sides[1]);
    if (!across || !down) return null;
    return longhands.map((lh, i) => {
        const stored = (t) => canon[lh]?.[t] ?? t;
        const h = stored(across[i]);
        const v = stored(down[i]);
        // A corner holds the pair, folded to one when the two agree -- which is
        // why a value with no `/` leaves every corner holding one component.
        return sameValue(h, v) ? h : `${h} ${v}`;
    });
}

// And what reading it back answers: each list is elided by the box rule
// *independently*, and the `/` goes only when the two come out identical.
function cornersJoin(values) {
    if (values.length !== 4) return null;
    const across = [];
    const down = [];
    for (const held of values) {
        const toks = components(held);
        if (!toks.length || toks.length > 2 || toks.includes('/')) return null;
        across.push(toks[0]);
        down.push(toks.length === 2 ? toks[1] : toks[0]);
    }
    const h = boxForm(across).join(' ');
    const v = boxForm(down).join(' ');
    return sameValue(h, v) ? h : `${h} / ${v}`;
}

// The model, if it gets no row *wrong* -- both directions, because one that
// expands right and serialises wrong leaves the declaration unreadable -- and
// declines every value Chrome threw away.
//
// Like a layer model, this one is allowed to *decline* a row Chrome accepted:
// keeping the declaration whole is the same answer as not modelling the
// shorthand at all, where placing a value wrongly is worse. The declines are
// counted and printed rather than swallowed. Without that licence the model
// would be all-or-nothing against a probe list it does not control -- adding a
// `calc()` value, which Chrome evaluates and this engine keeps byte for byte,
// would silently demote the shorthand back to `.unmodelled`.
//
// `legacy` is derived rather than assumed: the two-component reading is tried
// both ways round, and the one that has to decline least is recorded.
function cornersCandidate(longhands, plain, canon, classes, keywords, rejected) {
    if (longhands.length !== 4) return null;
    const takes = (lh, token) => {
        const cls = classify(token);
        if (cls.includes('identifier')) {
            const known = keywords[lh];
            if (known && known.includes(token.toLowerCase())) return true;
        }
        return cls.some((c) => (classes[lh] ?? []).includes(c));
    };
    let best = null;
    for (const legacy of [false, true]) {
        const declined = [];
        const ok = plain.every(([value, row]) => {
            const got = cornersExpand(value, longhands, canon, legacy, takes);
            if (!got) { declined.push(value); return true; }
            if (!got.every((x, i) => sameValue(x, row.v[i]))) return false;
            return sameValue(cornersJoin(row.v) ?? '', row.read);
        }) && rejected.every((value) =>
            cornersExpand(value, longhands, canon, legacy, takes) === null);
        // A model that placed nothing has not been tested by anything.
        const reached = plain.length - declined.length;
        if (!ok || reached === 0) continue;
        if (best && best.reached >= reached) continue;
        best = {
            kind: 'corners', group: 0, groups: 0, blocked: false,
            fill: new Array(4).fill('initial'), legacy, declined, reached,
        };
    }
    return best;
}

// --- the layer grammar ----------------------------------------------------

// `background` is not a run of components. It is a comma-separated list of
// layers, and inside a layer three things happen that no `.components` model
// can express: a position fills *two* longhands from one to four tokens whose
// order carries meaning (`top right` and `right top` both land x=right y=top,
// but `10px left` does not parse at all), a `/` introduces a size and may only
// sit straight after the position, and the colour belongs to the whole value
// rather than to a layer -- which is why it may only be written in the last one.
//
// Every part of that is read off the measured rows below and then checked
// against all of them: the width of a layer, which longhands the position
// fills, which one the slash introduces, what the axis the page did not write
// is left holding, and which keywords may carry an offset.
const NO_SLOT = 255;

// Top-level commas separate layers; parentheses and quotes hold.
function layersOf(value) {
    const out = [];
    let depth = 0, quote = null, cur = '';
    for (const ch of value) {
        if (quote) {
            cur += ch;
            if (ch === quote) quote = null;
            continue;
        }
        if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
        if (ch === '(') depth++;
        else if (ch === ')') depth--;
        else if (ch === ',' && depth === 0) { out.push(cur); cur = ''; continue; }
        cur += ch;
    }
    out.push(cur);
    return out.map((s) => s.trim());
}

// How many leading longhands are per-layer: the ones answering a comma list as
// long as the value had layers. The rest are shared by the whole value --
// `background-color` is one colour however many layers there are -- and a
// shorthand whose per-layer longhands are not a leading run is not this shape.
function layerWidth(plain) {
    let width = null;
    for (const [value, row] of plain) {
        const n = layersOf(value).length;
        if (n < 2) continue;
        const per = row.v.map((v) => layersOf(v).length === n);
        let w = 0;
        while (w < per.length && per[w]) w++;
        if (per.slice(w).some(Boolean)) return null;
        if (width === null) width = w;
        else if (width !== w) return null;
    }
    return width;
}

// Which axis a position token can be: the two axis longhands were measured
// separately, and `background-position-x` takes `left` where
// `background-position-y` takes `top`, so the token says where it goes.
function positionSlots(toks, m, accepts) {
    const [xi, yi] = m.axes;
    const axis = (t) => {
        const x = accepts(xi, t), y = accepts(yi, t);
        return x && y ? 'both' : x ? 'x' : y ? 'y' : null;
    };
    if (toks.length === 1) {
        const a = axis(toks[0]);
        if (!a) return null;
        return a === 'y' ? [m.implied, toks[0]] : [toks[0], m.implied];
    }
    if (toks.length === 2) {
        const [a, b] = toks;
        // Two keywords may come in either order (`top right` is x=right); once
        // a length is involved the order is fixed, which is why `10px left`
        // does not parse.
        const keyword = (t) => classify(t).includes('identifier');
        if (keyword(a) && keyword(b)) {
            const first = axis(a), second = axis(b);
            if (!first || !second) return null;
            if (first === 'y' || second === 'x') {
                return accepts(xi, b) && accepts(yi, a) ? [b, a] : null;
            }
        }
        return accepts(xi, a) && accepts(yi, b) ? [a, b] : null;
    }
    // Three or four tokens is two groups, each an edge keyword and maybe an
    // offset. `center` never carries one -- measured, through the axis
    // longhand's own acceptance -- so `center 10px top` does not parse.
    const splits = toks.length === 3 ? [[1, 2], [2, 1]] : toks.length === 4 ? [[2, 2]] : [];
    for (const [n1, n2] of splits) {
        if (n1 + n2 !== toks.length) continue;
        const groups = [toks.slice(0, n1), toks.slice(n1)];
        const seen = groups.map((g) => {
            if (g.length === 1) return { text: g[0], axis: axis(g[0]) };
            if (!classify(g[1]).some((c) => c === 'length' || c === 'percent')) return null;
            const x = m.offsets[0].includes(g[0].toLowerCase());
            const y = m.offsets[1].includes(g[0].toLowerCase());
            return { text: g.join(' '), axis: x && y ? 'both' : x ? 'x' : y ? 'y' : null };
        });
        if (seen.some((g) => !g || !g.axis)) continue;
        const [g1, g2] = seen;
        let out = null;
        if (g1.axis === 'x' && g2.axis !== 'x') out = [g1.text, g2.text];
        else if (g1.axis === 'y' && g2.axis !== 'y') out = [g2.text, g1.text];
        else if (g1.axis === 'both' && g2.axis === 'y') out = [g1.text, g2.text];
        else if (g1.axis === 'both' && g2.axis === 'x') out = [g2.text, g1.text];
        // A group of one is still a plain token and has to be accepted as one;
        // a group of two was already checked, by its edge carrying an offset.
        if (!out) continue;
        const fits = (slot, group, text) =>
            group.length === 2 || accepts(slot, text);
        if (fits(xi, out[0].split(' '), out[0]) && fits(yi, out[1].split(' '), out[1])) return out;
    }
    return null;
}

// How many components a slot takes as one value. Two of them take a pair --
// the size after the `/` and the repeat -- and every other slot stops at one.
// 0 means the slot cannot take even the first component.
function runLength(toks, m, accepts, slot) {
    if (!toks.length || toks[0] === '/' || !accepts(slot, toks[0])) return 0;
    if (!m.pairs.includes(slot) || toks.length < 2) return 1;
    if (toks[1] === '/' || !accepts(slot, toks[1])) return 1;
    return 2;
}

// One layer's tokens distributed over the slots, or null -- which is not a
// failure but a decline: the engine keeps a declaration it cannot place whole.
function parseLayer(toks, m, accepts, last, refuse) {
    if (toks.some((t) => refuse.has(t.toLowerCase()))) return null;
    const slots = new Array(m.total).fill(null);
    let i = 0, afterPosition = false, mirrored = false;
    while (i < toks.length) {
        const token = toks[i];
        if (token === '/') {
            if (!afterPosition || m.size === NO_SLOT || slots[m.size] !== null) return null;
            const n = runLength(toks.slice(i + 1), m, accepts, m.size);
            if (n === 0) return null;
            slots[m.size] = toks.slice(i + 1, i + 1 + n).join(' ');
            i += 1 + n;
            afterPosition = false;
            continue;
        }
        // The box pair. One token fills both -- `background: padding-box` moves
        // the origin *and* the clip -- and a second one takes the clip over.
        // Which slot a token can reach is the acceptance test: `text` is a clip
        // and not an origin, which is why `text border-box` lands the other way
        // round from how it was written.
        if (m.boxes && (accepts(m.boxes[0], token) || accepts(m.boxes[1], token))) {
            const [b1, b2] = m.boxes;
            if (slots[b1] === null && accepts(b1, token)) {
                slots[b1] = token;
                if (slots[b2] === null) {
                    slots[b2] = token;
                    mirrored = true;
                }
            } else if (accepts(b2, token) && (slots[b2] === null || mirrored)) {
                slots[b2] = token;
                mirrored = false;
            } else return null;
            afterPosition = false;
            i += 1;
            continue;
        }
        if (m.axes && slots[m.axes[0]] === null && slots[m.axes[1]] === null) {
            const room = toks.slice(i).findIndex((t) => t === '/');
            const limit = Math.min(4, room < 0 ? toks.length - i : room);
            let placed = false;
            for (let k = limit; k >= 1; k--) {
                const got = positionSlots(toks.slice(i, i + k), m, accepts);
                if (!got) continue;
                slots[m.axes[0]] = got[0];
                slots[m.axes[1]] = got[1];
                i += k;
                afterPosition = true;
                placed = true;
                break;
            }
            if (placed) continue;
        }
        let placed = 0;
        for (let s = 0; s < m.total; s++) {
            if (slots[s] !== null) continue;
            if (m.axes && (s === m.axes[0] || s === m.axes[1])) continue;
            if (m.boxes && (s === m.boxes[0] || s === m.boxes[1])) continue;
            if (s === m.size) continue;
            if (s >= m.width && !last) continue;   // shared, last layer only
            const n = runLength(toks.slice(i), m, accepts, s);
            if (n === 0) continue;
            slots[s] = toks.slice(i, i + n).join(' ');
            placed = n;
            break;
        }
        if (placed === 0) return null;
        afterPosition = false;
        i += placed;
    }
    return slots;
}

// The whole value: every layer's slots, and the shared ones taken from the
// last layer. Returns null when any layer declines.
function parseLayers(value, m, accepts, refuse) {
    const layers = layersOf(value);
    if (layers.some((l) => l.length === 0)) return null;
    const out = [];
    for (const [n, layer] of layers.entries()) {
        const got = parseLayer(components(layer), m, accepts, n === layers.length - 1, refuse);
        if (!got) return null;
        // Only the last layer may carry a shared slot, and an earlier layer
        // that reached one is a value Chrome would not have parsed.
        if (n !== layers.length - 1 && got.slice(m.width).some((v) => v !== null)) return null;
        out.push(got);
    }
    return out;
}

// What the stored longhand vector looks like: each per-layer longhand a comma
// list, each shared one a single value.
function layerVector(parsed, m, fill, stored) {
    const out = [];
    for (let s = 0; s < m.total; s++) {
        if (s >= m.width) {
            const held = parsed[parsed.length - 1][s];
            out.push(held === null ? fill[s] : stored(s, held));
            continue;
        }
        out.push(parsed.map((layer) => layer[s] === null ? fill[s] : stored(s, layer[s]))
            .join(', '));
    }
    return out;
}

// Reading the shorthand back: every slot that is not at its dropped value, in
// longhand order, with the size behind a `/` and the shared slots appended to
// the last layer.
function joinLayers(values, m, omit, empty, order, fill, accepts) {
    const per = values.map((v, s) => s < m.width ? layersOf(v) : [v]);
    const count = Math.max(...per.slice(0, m.width).map((l) => l.length));
    const out = [];
    for (let n = 0; n < count; n++) {
        const at = (s) => s < m.width ? per[s][n] : (n === count - 1 ? per[s][0] : undefined);
        const kept = [];
        for (const s of order) {
            // A collapsing box pair is written as a unit, and `mask` is the
            // reason the flag exists: with the two agreeing it writes one
            // component where `background` writes both, and with the origin at
            // its initial it still writes it -- unless the clip holds
            // something the origin could not.
            if (m.collapse && s === m.boxes[1]) continue;
            if (m.collapse && s === m.boxes[0]) {
                const [oi, ci] = m.boxes;
                const origin = at(oi), clip = at(ci);
                if (origin === undefined || clip === undefined) continue;
                const bare = (slot, held) => omit[slot].includes(held.toLowerCase());
                const o = bare(oi, origin) ? fill[oi] : origin;
                const c = bare(ci, clip) ? fill[ci] : clip;
                if (sameValue(o, c)) {
                    if (!bare(oi, origin)) kept.push(o);
                } else if (!accepts(oi, c) && bare(oi, origin)) {
                    kept.push(c);
                } else {
                    kept.push(o, c);
                }
                continue;
            }
            const held = at(s);
            if (held === undefined || omit[s].includes(held.toLowerCase())) continue;
            kept.push(s === m.size ? `/ ${held}` : held);
        }
        out.push(kept.length ? kept.join(' ') : empty);
    }
    return out.join(', ');
}

// The whole model, derived and then checked against every measured row. The
// hypotheses are which pair of longhands the position fills and which one the
// slash introduces; everything else follows from the rows.
function layerCandidate(longhands, plain, canon, classes, keywords, rejected) {
    const width = layerWidth(plain);
    if (width === null || width === 0) return null;
    const total = longhands.length;
    const stored = (i, t) => canon[longhands[i]]?.[t] ?? t;
    // The same acceptance test the engine will run, token by token: the
    // keyword table for an identifier, a measured value class otherwise. It has
    // to be the same test rather than a stricter one, or the model claims rows
    // the engine would place differently.
    const accepts = (i, token) => {
        const cls = classify(token);
        if (cls.includes('identifier')) {
            const known = keywords[longhands[i]];
            if (known && known.includes(token.toLowerCase())) return true;
        }
        return cls.some((c) => (classes[longhands[i]] ?? []).includes(c));
    };
    // A position and a size both take a length, so those are the slots worth
    // trying; anything else could not hold `10px`.
    const lengthy = [];
    for (let i = 0; i < width; i++) {
        if (accepts(i, '1px')) lengthy.push(i);
    }
    // A keyword may carry an offset where the axis longhand was measured
    // storing it with one: `background-position-x` keeps `left 10px` and
    // rejects `center 10px`, which is the whole reason `center 10px top` does
    // not parse.
    const offsetsFor = (i) => (keywords[longhands[i]] ?? []).filter((k) =>
        Object.keys(canon[longhands[i]] ?? {}).some((run) => {
            const parts = run.split(' ');
            return parts.length === 2 && parts[0].toLowerCase() === k &&
                classify(parts[1]).some((c) => c === 'length' || c === 'percent');
        }));
    // A slot whose value may be a *pair* of components rather than one, read
    // off the longhand itself: its canon carries a two-component run Chrome
    // kept, which no slot that takes only one does. `background-size` keeps
    // `1px 2px` and `background-repeat` answers `repeat no-repeat` with
    // `repeat-x`, where `background-attachment` throws `scroll fixed` away.
    // An axis's `left 10px` is not one of these -- that is an edge and its
    // offset, which `offsets` above already carries and the position
    // placement reads. Counting it would let a bare `mask-position` place
    // `left top` on one axis and lose the other.
    const pairSlots = [];
    for (let i = 0; i < width; i++) {
        const offsets = offsetsFor(i);
        const takesPair = Object.entries(canon[longhands[i]] ?? {}).some(([run, held]) => {
            if (held === '' || layersOf(run).length !== 1) return false;
            const parts = components(run);
            return parts.length === 2 && !offsets.includes(parts[0].toLowerCase());
        });
        if (takesPair) pairSlots.push(i);
    }

    const pairs = [null];
    for (const x of lengthy) {
        for (const y of lengthy) {
            if (x !== y) pairs.push([x, y]);
        }
    }
    // A box pair is two slots one token fills at once, found by looking for a
    // single-token row that moved two of them to the same value.
    const boxPairs = [null];
    for (const [value, row] of plain) {
        if (components(value).length !== 1 || layersOf(value).length !== 1) continue;
        for (let s1 = 0; s1 < width; s1++) {
            for (let s2 = s1 + 1; s2 < width; s2++) {
                if (!sameValue(row.v[s1], row.v[s2])) continue;
                if (!sameValue(stored(s1, value), row.v[s1])) continue;
                if (boxPairs.some((p) => p && p[0] === s1 && p[1] === s2)) continue;
                boxPairs.push([s1, s2]);
            }
        }
    }
    let best = null;
    for (const axes of pairs) {
        for (const boxes of boxPairs) {
            if (axes && boxes && (boxes.includes(axes[0]) || boxes.includes(axes[1]))) continue;
        for (const collapse of boxes ? [false, true] : [false]) {
        for (const size of [NO_SLOT, ...lengthy]) {
            if (axes && (size === axes[0] || size === axes[1])) continue;
            if (boxes && boxes.includes(size)) continue;
            const m = {
                total, width, axes, boxes, collapse, size, implied: '', offsets: [[], []],
                pairs: pairSlots,
            };
            if (axes) {
                m.offsets = [offsetsFor(axes[0]), offsetsFor(axes[1])];
                // What the axis the page did not write is left holding, taken
                // from a row that wrote one token and moved both.
                for (const [value, row] of plain) {
                    if (components(value).length !== 1 || layersOf(value).length !== 1) continue;
                    const x = row.v[axes[0]], y = row.v[axes[1]];
                    if (sameValue(x, y)) continue;
                    if (sameValue(stored(axes[0], value), x)) { m.implied = y; break; }
                    if (sameValue(stored(axes[1], value), y)) { m.implied = x; break; }
                }
            }
            // What a slot the parse left alone holds. Taken by weight rather
            // than by agreement: `background: border-area` moves the origin to
            // `border-box` where every other row leaves it `initial`, and one
            // such row must not be able to claim the filler.
            const parsed = new Map();
            const votes = Array.from({ length: total }, () => new Map());
            const seen = new Set();
            for (const [value, row] of plain) {
                const got = parseLayers(value, m, accepts, seen);
                if (!got) continue;
                parsed.set(value, got);
                for (let s = 0; s < total; s++) {
                    const layers = s < width ? layersOf(row.v[s]) : [row.v[s]];
                    for (const [n, layer] of got.entries()) {
                        if (layer[s] !== null || layers[n] === undefined) continue;
                        if (s >= width && n !== got.length - 1) continue;
                        const held = layers[n].toLowerCase();
                        votes[s].set(held, (votes[s].get(held) ?? 0) + 1);
                    }
                }
            }
            if (!parsed.size) continue;
            const filler = votes.map((slot) => [...slot.entries()]
                .sort((a, b) => b[1] - a[1])[0]?.[0] ?? 'initial');
            // A row the model gets *wrong* is not allowed. A keyword-only value
            // whose row it cannot reproduce is refused instead: the engine
            // declines a declaration carrying one and keeps it whole, which is
            // the same answer as not modelling the shorthand at all.
            const refuse = new Set();
            const refusable = (value) => {
                const toks = components(value);
                if (toks.length !== 1 || layersOf(value).length !== 1) return false;
                const cls = classify(toks[0]);
                if (!cls.includes('identifier')) return false;
                return !longhands.some((lh, i) => i < total &&
                    (classes[lh] ?? []).includes('identifier'));
            };
            let ok = true;
            for (const [value, got] of [...parsed]) {
                const row = plain.find(([v]) => v === value)[1];
                const want = layerVector(got, m, filler, stored);
                if (want.every((v, i) => sameValue(v, row.v[i]))) continue;
                if (refusable(value)) {
                    refuse.add(value.toLowerCase());
                    parsed.delete(value);
                    continue;
                }
                ok = false;
                break;
            }
            // And a value Chrome threw away has to be declined, not placed:
            // `-webkit-mask: no-clip` does not parse where `mask: no-clip` does,
            // and both spellings reach the same clip longhand, so only the
            // shorthand's own reading says so.
            for (const value of rejected) {
                if (!parseLayers(value, m, accepts, refuse)) continue;
                if (!refusable(value)) {
                    ok = false;
                    break;
                }
                refuse.add(components(value)[0].toLowerCase());
            }
            if (!ok || !parsed.size) continue;
            for (const value of rejected) {
                if (parseLayers(value, m, accepts, refuse)) { ok = false; break; }
            }
            if (!ok) continue;
            for (const value of [...parsed.keys()]) {
                if (!parseLayers(value, m, accepts, refuse)) parsed.delete(value);
            }
            if (!parsed.size) continue;
            // Then the reading back, whose dropped values are forced by the
            // rows the same way `.components`' are: a slot holding something
            // the reading does not show was left out.
            const rows = [...parsed.keys()].map((v) => [v, plain.find(([w]) => w === v)[1]]);
            const omit = Array.from({ length: total }, () => new Set());
            for (const [, row] of rows) {
                const shown = layersOf(row.read).map(components);
                const lists = row.v.map((v, s) => s < width ? layersOf(v) : [v]);
                const count = Math.max(...lists.slice(0, width).map((l) => l.length));
                for (let n = 0; n < count; n++) {
                    for (let s = 0; s < total; s++) {
                        const held = s < width ? lists[s][n] : (n === count - 1 ? lists[s][0] : undefined);
                        if (held === undefined) continue;
                        const seen = shown[n] ?? [];
                        if (components(held).every((t) => seen.includes(t))) continue;
                        omit[s].add(held.toLowerCase());
                    }
                }
            }
            const flat = omit.map((s) => [...s].sort());
            // What a layer whose every slot dropped serialises to. `mask`
            // answers `none` there; for `background` no probe value reaches it,
            // and "" is what the search settles on when nothing exercises it.
            // The order the kept components come back in is not always the
            // order the longhands are stored in: `transition` stores its
            // property last and writes it first. No one reading shows the whole
            // order, so the pairs are collected across the rows and sorted.
            const identity = [...Array(total).keys()];
            const derived = (() => {
                const after = Array.from({ length: total }, () => new Set());
                for (const [, r] of rows) {
                    const shown = components(layersOf(r.read)[0] ?? '');
                    const seen = [];
                    for (const s of identity) {
                        if (m.collapse && s === m.boxes[1]) continue;
                        const held = s < width ? layersOf(r.v[s])[0] : r.v[s];
                        if (held === undefined || flat[s].includes(held.toLowerCase())) continue;
                        const at = shown.indexOf(components(held)[0]);
                        if (at >= 0) seen.push([s, at]);
                    }
                    seen.sort((a, b) => a[1] - b[1]);
                    for (let k = 1; k < seen.length; k++) after[seen[k][0]].add(seen[k - 1][0]);
                }
                const out = [];
                while (out.length < total) {
                    const next = identity.find((s) => !out.includes(s) &&
                        [...after[s]].every((prior) => out.includes(prior)));
                    if (next === undefined) return null;
                    out.push(next);
                }
                return out;
            })();
            const empties = ['', ...new Set(rows.map(([, r]) => r.read))];
            let order = null;
            const empty = empties.find((candidate) => [identity, derived]
                .filter(Boolean).some((attempt) => {
                    const fits = rows.every(([, r]) => sameValue(
                        joinLayers(r.v, m, flat, candidate, attempt, filler, accepts), r.read));
                    if (fits) order = attempt;
                    return fits;
                }));
            if (empty === undefined) continue;
            // A slot no accepted row ever reached is not evidence of a slot.
            const reached = new Set();
            for (const [, got] of parsed) {
                for (const layer of got) {
                    layer.forEach((v, s) => { if (v !== null) reached.add(s); });
                }
            }
            // A per-layer slot no accepted row ever reached is not evidence of
            // a slot. A shared one may go unreached -- `animation` has three no
            // probe value touches -- and still be there, since the layer
            // structure says where the shared ones start.
            if (![...Array(width).keys()].every((s) => reached.has(s))) continue;
            // Several shapes can reproduce the rows; the one that reproduces
            // the most of them is the one kept, and a position beats a box pair
            // on a tie because it is the narrower claim.
            const score = [parsed.size, axes ? 1 : 0, boxes ? 0 : 1, collapse ? 0 : 1];
            if (best && !score.some((v, i) => v > best.score[i] &&
                score.slice(0, i).every((w, j) => w === best.score[j]))) continue;
            best = { score, model: {
                kind: 'layers', group: 0, groups: 0, blocked: false, fill: filler,
                layer_width: width, axes, size, implied: m.implied,
                boxes, collapse, pairs: pairSlots, offsets: m.offsets, omit: flat, empty,
                order: order.every((v, i) => v === i) ? [] : order,
                refuse: [...refuse].sort(),
                declined: plain.filter(([v]) => !parsed.has(v)).map(([v]) => v),
                reached: parsed.size,
            } };
        }
        }
        }
    }
    return best?.model ?? null;
}

// --- run ------------------------------------------------------------------

// Deriving the models from the readings is the fiddly half, and it does not
// need a browser: DUMP writes the raw readings out and LOAD replays them, so a
// change to a model can be checked against the same Chrome that produced them.
// The keyword table already knows which identifiers each property takes, and it
// is the half of the acceptance test a value class cannot carry: `solid` and
// `red` are both identifiers, and only the keyword list says one belongs to a
// style and the other to a colour.
const keywords = {};
{
    const source = await fs.readFile(
        path.join(repo, 'src/browser/webapi/css/chrome_keywords.zig'), 'utf8');
    for (const m of source.matchAll(/^    \.\{ "([^"]+)", (&\.\{[^\n]*?\}) \},$/gm)) {
        keywords[m[1]] = [...m[2].matchAll(/"([^"]*)"/g)].map((k) => k[1].toLowerCase());
    }
}

async function measure() {
    if (process.env.LOAD) {
        return JSON.parse(await fs.readFile(process.env.LOAD, 'utf8'));
    }
    const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'cssshort-'));
    const proc = spawn(CHROME, [
        ...(process.argv.includes('--headed') ? [] : ['--headless=new']),
        `--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`,
        '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
    ], { stdio: ['ignore', 'ignore', 'ignore'] });
    try {
        const names = await candidateNames();
        process.stderr.write(`candidate property names: ${names.length}\n`);
        // Every component any probe value can decompose into, so the canonical
        // form each longhand stores it as is known before a row is explained.
        // A slot can hold more than one component -- a position edge with an
        // offset, a two-value size -- so the canonical form of every adjacent
        // pair is measured as well. That is also the only test that says
        // `left 10px` is a position and `center 10px` is not.
        const runs = VALUES.flatMap((value) => {
            const toks = components(value);
            return toks.slice(1).map((t, i) => [toks[i], t]);
        }).filter(([a, b]) => a !== '/' && b !== '/').map((pair) => pair.join(' '));
        const tokens = [...new Set([
            ...Object.values(CLASS_TOKENS),
            ...VALUES.flatMap(components).filter((t) => t !== '/'),
            ...runs,
            // And every probe value whole, so what a longhand stores for it is
            // measured rather than assumed to be the text as written:
            // `perspective-origin` keeps `top 20px left 10px` as
            // `left 10px top 20px`, and without this that reads as a rename.
            ...VALUES,
        ])].filter((t) => !CSS_WIDE.includes(t.toLowerCase()));
        process.stderr.write(`probe tokens: ${tokens.length}\n`);

        await sleep(1800);
        const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
        const { sessionId } = await newPage(cdp);
        await cdp.send('Page.navigate', { url: PAGE }, sessionId);
        await sleep(1200);
        const extra = {};
        for (const name of names) {
            const own = (keywords[name] ?? []).filter((k) => !CSS_WIDE.includes(k));
            if (own.length) extra[name] = own;
        }
        const measured = JSON.parse(await evaluate(cdp, sessionId,
            PROBE(names, VALUES, CLASS_TOKENS, tokens, extra)));
        cdp.close();
        if (process.env.DUMP) {
            await fs.writeFile(process.env.DUMP, JSON.stringify(measured));
        }
        return measured;
    } finally {
        proc.kill('SIGKILL');
        await fs.rm(prof, { recursive: true, force: true }).catch(() => {});
    }
}

{
    const measured = await measure();
    const { userAgent, expansion, classes, canon, rows, rejected } = measured;

    const shorthands = {};
    const demoted = [];
    for (const [name, wideOrder] of Object.entries(expansion)) {
        const width = wideOrder.length;
        const all = Object.entries(rows[name] ?? {});
        const plain = all.filter(([v]) => !CSS_WIDE.includes(v.toLowerCase()));
        const wideOk = all.filter(([v]) => CSS_WIDE.includes(v.toLowerCase()))
            .every(([v, r]) => r.v.every((x) => sameValue(x, v)));
        // The order is not one order. Nine shorthands enumerate their longhands
        // one way for a CSS-wide keyword and another for a real value --
        // `border: inherit` is colour/style/width per side, `border: 1px` is all
        // four widths, then all four styles, then all four colours -- so both
        // are kept, since `item(i)` answers whichever applies.
        const orders = [...new Set(plain.map(([, r]) => r.items.join(',')))];
        const longhands = orders.length === 1 ? orders[0].split(',') : wideOrder;

        let chosen = null;
        if (!wideOk) {
            demoted.push([name, 'a CSS-wide keyword does not reach every longhand']);
        } else if (!plain.length) {
            // A rename has nothing to distribute, so there is nothing a probe
            // value could disagree with: `-webkit-box-sizing` is `box-sizing`
            // whether or not any offered value happened to parse.
            if (width === 1) chosen = { kind: 'alias', group: 1, groups: 1, blocked: false, fill: ['initial'] };
            else demoted.push([name, 'no probe value parsed']);
        } else if (orders.length > 1) {
            demoted.push([name, `${orders.length} different longhand orders`]);
        } else {
            // A comma is a layer boundary, and the narrower models have no
            // layers: they are derived from the rows without one and have to
            // *decline* the rest, which is what the engine does with a value it
            // cannot place. Getting one wrong is still a demotion.
            const simple = plain.filter(([v]) => layersOf(v).length === 1);
            const layered = plain.filter(([v]) => layersOf(v).length > 1);
            const measuredFill = fillers(simple, width, longhands, canon);
            const fill = measuredFill ?? new Array(width).fill('initial');
            {
                // A rename can still rewrite the value: `page-break-after:
                // always` is stored as `break-after: page` and the -webkit-
                // column spelling as `column`. Four properties do it, all
                // measured rather than assumed.
                if (width === 1) {
                    const lh = longhands[0];
                    const translate = simple
                        .filter(([v, r]) => !sameValue(r.v[0], canon[lh]?.[v] ?? v))
                        .map(([v, r]) => [v.toLowerCase(), r.v[0]]);
                    if (translate.every(([v]) => classify(v).includes('identifier'))) {
                        chosen = { kind: 'alias', group: 1, groups: 1, blocked: false, fill, translate };
                    }
                }
                const candidates = [];
                if (width === 4) candidates.push(['box4', 4, 1, false]);
                if (width === 2) candidates.push(['box2', 2, 1, false]);
                // Prefer the most repetition: `border` is four groups of three
                // rather than one flat run of twelve, and only the repeating
                // reading puts `border: 1px solid red` on all four sides.
                for (let g = 1; g <= width; g++) {
                    for (let k = Math.floor(width / g); k >= 1; k--) {
                        candidates.push(['components', g, k, false]);
                        if (k > 1) candidates.push(['components', g, k, true]);
                    }
                }
                candidates.sort((a, b) => (b[2] - a[2]) || (b[1] * b[2] - a[1] * a[2]));
                // No single filler explains the readings means no distribution
                // rule can either -- but a lookup table still might, so the
                // preset gate below still gets its turn.
                for (const [kind, g, k, blocked] of (chosen || !measuredFill) ? [] : candidates) {
                    const used = new Set();
                    const ok = simple.every(([value, row]) => {
                        const got = expand(kind, value, longhands, fill, g, k, blocked,
                            classes, keywords, canon, used);
                        return got && got.length === width &&
                            got.every((x, i) => sameValue(x, row.v[i]));
                    });
                    // A component slot no measured value ever reached is not
                    // evidence of a slot. Without this, `border` reads as four
                    // groups of four -- the fourth slot covering border-image,
                    // which nothing it accepts can ever land in -- rather than
                    // the four groups of three it is.
                    if (!ok || (kind === 'components' && used.size !== g)) continue;
                    chosen = { kind, group: g, groups: k, blocked, fill };
                    break;
                }
                // A shorthand whose whole value space is one keyword at a time
                // can be tabulated outright, and two of them have to be:
                // `white-space: nowrap` is `collapse` plus `nowrap`, which no
                // distribution rule produces. The gate is that *every* value
                // that parsed was a single keyword the keyword table already
                // lists -- so a page cannot write one this table has not seen.
                if (!chosen) {
                    const own = (keywords[name] ?? []).filter((k) => !CSS_WIDE.includes(k));
                    const listed = simple.filter(([v]) => components(v).length === 1 &&
                        classify(v).includes('identifier') && own.includes(v.toLowerCase()));
                    const covered = own.every((k) => simple.some(([v]) => sameValue(v, k)));
                    // The gate is that a single keyword is *all* a page can
                    // write here: relax it and the lookup swallows every
                    // shorthand with a keyword list, declining the values that
                    // matter.
                    if (own.length && listed.length === simple.length && covered) {
                        chosen = {
                            kind: 'presets', group: 0, groups: 0, blocked: false,
                            fill: fill,
                            presets: listed.map(([v, r]) => [v.toLowerCase(), r.v]),
                        };
                    }
                }
                // Then the corner shape, which -- like the layered one below --
                // has to run even when no single filler explained a row: a
                // corner holds a *pair*, and `fillers` compares a slot against
                // the value's own tokens, so it cannot see one.
                if (!chosen) {
                    chosen = cornersCandidate(longhands, plain, canon, classes, keywords,
                        rejected?.[name] ?? []);
                }
                // Last, the layered shapes. It goes after everything else so a
                // shorthand already modelled cannot change model: the narrower
                // one reproduces every row too, and there is nothing to gain
                // from re-reading `border` as a list of layers.
                if (!chosen) {
                    chosen = layerCandidate(longhands, plain, canon, classes, keywords,
                        rejected?.[name] ?? []);
                }
                if (!chosen) {
                    demoted.push([name, measuredFill
                        ? 'no model reproduces every row'
                        : 'no single filler explains every row']);
                }
            }
        }

        // A rename has no shorthand serialisation of its own: cssText names the
        // longhand it renamed to, so it has no fillers worth recording either.
        if (chosen && chosen.kind === 'alias') chosen.fill = new Array(width).fill('initial');

        // Expanding is only half of it: `getPropertyValue('border-top')` and
        // cssText have to put the longhands back together, and a model that
        // cannot do that would leave the declaration unreadable -- worse than
        // not expanding at all. So the rule is derived and checked here, and a
        // shorthand it fails on is demoted with the rest.
        const single = plain.filter(([v]) => layersOf(v).length === 1);
        // A rename is the exception: it hands the value to its one longhand
        // whole, so a comma list is that longhand's business and not a layer
        // boundary it has to decline. So is a corner model, which was already
        // checked against every row -- comma-carrying ones included -- and
        // against everything Chrome rejected, by `cornersCandidate`.
        if (chosen && chosen.kind !== 'layers' && chosen.kind !== 'alias' &&
            chosen.kind !== 'corners')
        {
            const wrong = plain.filter(([v]) => layersOf(v).length > 1).find(([value]) =>
                expand(chosen.kind, value, longhands, chosen.fill, chosen.group,
                    chosen.groups, chosen.blocked, classes, keywords, canon) !== null);
            if (wrong) {
                demoted.push([name, `answers ${JSON.stringify(wrong[0])} rather than declining it`]);
                chosen = null;
            }
        }
        // `.layers` and `.corners` derive and check their own reconstruction, so
        // they are past this gate rather than exempt from one.
        if (chosen && chosen.kind !== 'unmodelled' && chosen.kind !== 'layers' &&
            chosen.kind !== 'corners')
        {
            const bad = serialisation(name, chosen, longhands, single);
            if (bad) {
                demoted.push([name, bad]);
                chosen = null;
            }
        }

        const wide = wideOrder.join(',') === longhands.join(',') ? [] : wideOrder;
        shorthands[name] = chosen
            ? { empty: null, fallback: [], ...chosen, longhands, wide }
            : { kind: 'unmodelled', longhands, wide, group: 0, groups: 0, fill: [], empty: null, fallback: [] };
    }

    const kindCount = {};
    for (const s of Object.values(shorthands)) kindCount[s.kind] = (kindCount[s.kind] ?? 0) + 1;
    process.stderr.write(`shorthands: ${Object.keys(shorthands).length} -- ` +
        Object.entries(kindCount).sort().map(([k, n]) => `${k} ${n}`).join(', ') + '\n');
    for (const [name, reason] of demoted) process.stderr.write(`  unmodelled ${name}: ${reason}\n`);
    // A layer or corner model is allowed to decline a row -- the engine keeps a
    // value it cannot place whole, which is the same answer as not modelling the
    // shorthand at all. It is not allowed to get one wrong, so the declines are
    // printed rather than swallowed.
    for (const [name, s] of Object.entries(shorthands)) {
        if ((s.kind !== 'layers' && s.kind !== 'corners') || !s.declined?.length) continue;
        process.stderr.write(`  ${name} declines ${s.declined.length} of ` +
            `${s.declined.length + s.reached} probe values: ` +
            s.declined.map((v) => JSON.stringify(v)).join(', ') + '\n');
    }

    const names_ = Object.keys(shorthands).sort();
    const classNames = Object.keys(CLASS_TOKENS);
    const longhandNames = Object.keys(classes).sort();

    const lines = [
        '// GENERATED by tools/fingerprint/dump-css-shorthands.mjs — do not hand-edit.',
        '//',
        `// Measured from ${userAgent}`,
        `// ${names_.length} shorthands over ${VALUES.length} probe values.`,
        '//',
        '// Chrome does not store a shorthand. It expands one into its longhands, so',
        '// `border: 1px solid red` is seventeen entries in the declaration and both',
        '// `getPropertyValue(\'border\')` and `cssText` are rebuilt from them.',
        '//',
        '// `longhands` is that list in Chrome\'s own order, which is what `item(i)`',
        '// answers. `fillers` is what a longhand the value never mentioned is left',
        '// holding, and it is measured per shorthand because Blink is not consistent:',
        '// `text-decoration: red` leaves the other three reading the literal `initial`',
        '// where `border-top: red` leaves `medium` and `none`, the initial values',
        '// spelled out.',
        '//',
        '// `kind` is how the value\'s components reach the longhands, and each one was',
        '// checked against every probe value that parsed before being written here:',
        '//',
        ...Object.entries(kindCount).sort().map(([k, n]) =>
            `//   ${(k + ' ').padEnd(12)}${String(n).padStart(3)}  ${KIND_NOTES[k]}`),
        '//',
        '// The unmodelled ones are the shorthands with a real grammar behind them,',
        ...wrap(demoted.map(([n]) => n).filter((n) => !n.startsWith('-webkit-')).join(', ') + ','),
        '// plus their -webkit- spellings. The engine keeps those whole, so',
        '// `style.length` answers 1 where Chrome says 9: a visible difference, but a',
        '// smaller one than nine invented values.',
        '',
        'const std = @import("std");',
        '',
        'pub const Kind = enum { alias, box4, box2, components, presets, corners, layers, unmodelled };',
        '',
        '/// A slot the layer grammar has no longhand for: `.axes` and `.size_slot`',
        '/// hold it when the shorthand has no position or no `/`.',
        'pub const no_slot: u8 = 255;',
        '',
        '/// The value classes a longhand accepts, by the shape of the component. The',
        '/// keyword half of the same test lives in chrome_keywords.zig: `solid` and',
        '/// `red` are both identifiers and only the keyword list tells them apart.',
        'pub const Class = enum { ' + classNames.join(', ') + ' };',
        '',
        'pub const Shorthand = struct {',
        '    kind: Kind,',
        '    longhands: []const []const u8,',
        '    /// The order `item(i)` answers for a CSS-wide keyword, on the nine',
        '    /// shorthands where Chrome enumerates that case differently. Empty',
        '    /// means `longhands` covers both.',
        '    wide_longhands: []const []const u8 = &.{},',
        '    /// Parallel to `longhands`; empty when the kind is `.unmodelled`.',
        '    fillers: []const []const u8,',
        '    /// For `.components`: how many longhands one group covers, and how many',
        '    /// times it repeats. Longhands past `group * groups` always take their',
        '    /// filler (`border`\'s five border-image longhands).',
        '    group: u8 = 0,',
        '    groups: u8 = 0,',
        '    /// How the repeats are laid out. `rule` repeats the group in place',
        '    /// (width, style, colour, width, style, colour); `border` blocks it',
        '    /// (four widths, then four styles, then four colours). Measured, and',
        '    /// only visible because `item(i)` answers the order.',
        '    blocked: bool = false,',
        '    /// For `.components`: the value each slot is *dropped* at when the',
        '    /// shorthand is put back together, one per slot of the group. Blink',
        '    /// leaves out a component holding its initial value, which is why',
        '    /// `text-decoration: 1px solid red` answers `1px red` -- `solid` is',
        '    /// text-decoration-style\'s initial. A slot can have more than one:',
        '    /// text-decoration\'s colour is dropped both for the literal `initial`',
        '    /// and for `currentcolor`, its initial value spelled out.',
        '    omit: []const []const []const u8 = &.{},',
        '    /// The order the kept components are written back in, when it is not',
        '    /// the order the longhands are stored in. `transition` stores its',
        '    /// behaviour first and writes its property first.',
        '    order: []const u8 = &.{},',
        '    /// What the shorthand serialises to once every longhand holds its filler.',
        '    /// Measured, and Blink is not consistent: `column-rule` answers its width',
        '    /// (`medium`), `text-decoration` its line (`none`), and `border` answers',
        '    /// nothing -- an empty string here means cssText falls back to `fallback`.',
        '    empty: ?[]const u8 = null,',
        '    /// The sub-shorthands cssText writes instead when `empty` is "".',
        '    fallback: []const []const u8 = &.{},',
        '    /// For `.alias`: values the rename also rewrites. `page-break-after:',
        '    /// always` is stored as `break-after: page`, and the -webkit- column',
        '    /// spelling as `column`. Everything not listed passes through.',
        '    translate: []const struct { []const u8, []const u8 } = &.{},',
        '    /// For `.presets`: the whole value space, one keyword at a time. Used',
        '    /// where no distribution rule reproduces the readings and the keyword',
        '    /// table says a single keyword is all a page can write --',
        '    /// `white-space: nowrap` is `collapse` and `nowrap`, which is a',
        '    /// lookup, not a rule.',
        '    presets: []const struct { []const u8, []const []const u8, []const u8 } = &.{},',
        '    /// For `.layers`: how many leading longhands are per-layer. The rest are',
        '    /// shared by the whole value and only the last layer may write them --',
        '    /// `background-color` is one colour however many layers there are, which',
        '    /// is why `background: red, blue` does not parse and `url(a), red` does.',
        '    layer_width: u8 = 0,',
        '    /// For `.layers`: the two longhands one position fills, and what the',
        '    /// axis the page did not write is left holding (`center`). A position',
        '    /// takes one to four components and their order carries meaning:',
        '    /// `top right` and `right top` both land x=right y=top, and `10px left`',
        '    /// does not parse at all.',
        '    axes: [2]u8 = .{ no_slot, no_slot },',
        '    implied: []const u8 = "",',
        '    /// For `.layers`: the two longhands one box component fills at once.',
        '    /// `background: padding-box` moves the origin *and* the clip, and a',
        '    /// second component takes the clip over -- `text` is a clip and not an',
        '    /// origin, so `text border-box` lands the other way round from how it',
        '    /// was written.',
        '    boxes: [2]u8 = .{ no_slot, no_slot },',
        '    /// For `.layers`: whether the box pair is written as one component',
        '    /// when the two agree. `mask: content-box content-box` answers one',
        '    /// `content-box` where `background: content-box` answers two, and with',
        '    /// the origin at its initial the pair still writes it -- unless the clip',
        '    /// holds a value the origin could not take, which is why',
        '    /// `mask: border-box no-clip` answers just `no-clip`.',
        '    box_collapse: bool = false,',
        '    /// For `.layers`: the longhand a `/` introduces, which may only sit',
        '    /// straight after the position -- `url(a) / 20px` does not parse.',
        '    size_slot: u8 = no_slot,',
        '    /// For `.layers`: the slots whose value may be a pair of',
        '    /// components rather than one. Read off the longhand: its canon',
        '    /// carries a two-component run Chrome kept, which no slot taking',
        '    /// a single component does. The size and the repeat are the two,',
        '    /// so `left top / 10px 20px` and `repeat no-repeat` are layers',
        '    /// rather than declines -- the pair reaches the longhand whole',
        '    /// and is shortened there (`repeat no-repeat` is `repeat-x`).',
        '    /// An axis is not one of these: its `left 10px` is an edge and',
        '    /// its offset, which `offsets` carries and `positionSlots` reads.',
        '    pairs: []const u8 = &.{},',
        '    /// For `.layers`: values the model cannot express, so the engine',
        '    /// declines a declaration carrying one and keeps it whole.',
        '    /// `background: border-area` is the one: it moves the origin to',
        '    /// `border-box` where `background: text` -- the same shape of value,',
        '    /// a clip-only keyword -- leaves it alone.',
        '    refuse: []const []const u8 = &.{},',
        '    /// For `.layers`: per axis, the keywords that may carry an offset.',
        '    /// Measured through the axis longhand itself: it stores `left 10px`',
        '    /// and rejects `center 10px`, which is what makes `center 10px top`',
        '    /// fail to parse.',
        '    offsets: []const []const []const u8 = &.{},',
        '    /// For `.corners`: whether *exactly* two components are read as the',
        '    /// legacy WebKit horizontal-then-vertical form rather than by the box',
        '    /// rule. The one place the two parsers disagree, measured:',
        '    /// `-webkit-border-radius: 10px 20px` is `10px / 20px` where',
        '    /// `border-radius: 10px 20px` is itself. One and three and four',
        '    /// components land the same way under both spellings.',
        '    legacy_pair: bool = false,',
        '    /// For `.alias`: what reading back through the *old* name answers when',
        '    /// it is not simply the stored value. Not the inverse of `translate`:',
        '    /// `page-break-after` answers `always` for a stored `page`, and the',
        '    /// -webkit- column spellings answer nothing at all.',
        '    reads: []const struct { []const u8, []const u8 } = &.{},',
        '};',
        '',
        'pub const shorthands = std.StaticStringMap(Shorthand).initComptime(.{',
        ...names_.map((n) => {
            const s = shorthands[n];
            const parts = [
                `.kind = .${s.kind}`,
                `.longhands = ${zigList(s.longhands)}`,
                `.fillers = ${zigList(s.fill)}`,
            ];
            if (s.kind === 'components') {
                parts.push(`.group = ${s.group}`, `.groups = ${s.groups}`);
                if (s.blocked) parts.push('.blocked = true');
                parts.push('.omit = ' + zigSeq(s.omit.map(zigList)));
                if (s.order?.length) {
                    parts.push('.order = ' + zigSeq(s.order.map(String)));
                }
            }
            if (s.kind === 'corners' && s.legacy) parts.push('.legacy_pair = true');
            if (s.kind === 'layers') {
                parts.push(`.layer_width = ${s.layer_width}`);
                if (s.axes) parts.push(`.axes = .{ ${s.axes[0]}, ${s.axes[1]} }`);
                if (s.implied) parts.push(`.implied = ${zigString(s.implied)}`);
                if (s.boxes) parts.push(`.boxes = .{ ${s.boxes[0]}, ${s.boxes[1]} }`);
                if (s.collapse) parts.push('.box_collapse = true');
                if (s.size !== 255) parts.push(`.size_slot = ${s.size}`);
                if (s.pairs.length) parts.push('.pairs = ' + zigSeq(s.pairs.map(String)));
                if (s.refuse.length) parts.push(`.refuse = ${zigList(s.refuse)}`);
                parts.push('.offsets = ' + zigSeq(s.offsets.map(zigList)));
                parts.push('.omit = ' + zigSeq(s.omit.map(zigList)));
                if (s.order.length) parts.push('.order = ' + zigSeq(s.order.map(String)));
            }
            if (s.wide.length) parts.push(`.wide_longhands = ${zigList(s.wide)}`);
            if (s.translate?.length) {
                parts.push('.translate = ' + zigSeq(s.translate
                    .map(([from, to]) => `.{ ${zigString(from)}, ${zigString(to)} }`)));
            }
            if (s.presets?.length) {
                parts.push('.presets = ' + zigSeq(s.presets
                    .map(([v, vec, read]) => `.{ ${zigString(v)}, ${zigList(vec)}, ${zigString(read)} }`)));
            }
            if (s.reads?.length) {
                parts.push('.reads = ' + zigSeq(s.reads
                    .map(([from, to]) => `.{ ${zigString(from)}, ${zigString(to)} }`)));
            }
            if (s.empty !== null) parts.push(`.empty = ${zigString(s.empty)}`);
            if (s.fallback.length) parts.push(`.fallback = ${zigList(s.fallback)}`);
            // Named rather than inferred: StaticStringMap takes the pairs as an
            // anonymous tuple, so the value has nothing to infer its type from.
            return `    .{ ${zigString(n)}, Shorthand{ ${parts.join(', ')} } },`;
        }),
        '});',
        '',
        '/// Which value classes each longhand a shorthand expands into accepts,',
        `/// measured by writing one representative token per class to it:`,
        ...classNames.map((c) => `///   ${c.padEnd(11)}${CLASS_TOKENS[c]}`),
        'pub const value_classes = std.StaticStringMap([]const Class).initComptime(.{',
        ...longhandNames.map((lh) => {
            const list = zigSeq(classes[lh].map((c) => '.' + c));
            return `    .{ ${zigString(lh)}, ${list} },`;
        }),
        '});',
        '',
    ].join('\n');

    await fs.writeFile(outPath, lines);
    process.stderr.write(`wrote ${outPath}\n`);
}
