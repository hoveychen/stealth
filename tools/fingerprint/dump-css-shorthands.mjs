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
// A shorthand no model reproduces is emitted as `.unmodelled` and the engine
// keeps it whole, which is the safe direction: a page reading `style.length`
// sees 1 instead of 9, where a wrong expansion would answer nine wrong values.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, newPage, evaluate, sleep } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = process.env.CHROME ??
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT ?? 9493);
const outPath = path.join(repo, 'src/browser/webapi/css/chrome_shorthands.zig');

// Same pin as the keyword and value-case tables.
const MDN_DATA = '2.24.0';

const CSS_WIDE = ['inherit', 'initial', 'unset', 'revert', 'revert-layer'];

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
  const canon = {};
  for (const lh of longhands) {
    const seen = {};
    for (const token of ${JSON.stringify(tokens)}) {
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
  const extra = ${JSON.stringify(extra)};
  const rows = {};
  for (const name of Object.keys(expansion)) {
    const got = {};
    for (const value of ${JSON.stringify(values)}.concat(extra[name] ?? [])) {
      const snapped = set(name, value);
      if (!snapped) continue;
      got[value] = {
        items: snapped.items,
        v: snapped.v,
        cssText: el.style.cssText,
        read: el.style.getPropertyValue(name),
      };
    }
    rows[name] = got;
  }

  return JSON.stringify({ userAgent: navigator.userAgent, expansion, classes, canon, rows });
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
    if (/\(.*\)$/.test(token)) return ['function'];
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
        '--no-first-run', '--no-default-browser-check',
    ], { stdio: ['ignore', 'ignore', 'ignore'] });
    try {
        const names = await candidateNames();
        process.stderr.write(`candidate property names: ${names.length}\n`);
        // Every component any probe value can decompose into, so the canonical
        // form each longhand stores it as is known before a row is explained.
        const tokens = [...new Set([
            ...Object.values(CLASS_TOKENS),
            ...VALUES.flatMap(components).filter((t) => t !== '/'),
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
    const { userAgent, expansion, classes, canon, rows } = measured;

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
            const measuredFill = fillers(plain, width, longhands, canon);
            const fill = measuredFill ?? new Array(width).fill('initial');
            {
                // A rename can still rewrite the value: `page-break-after:
                // always` is stored as `break-after: page` and the -webkit-
                // column spelling as `column`. Four properties do it, all
                // measured rather than assumed.
                if (width === 1) {
                    const lh = longhands[0];
                    const translate = plain
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
                    const ok = plain.every(([value, row]) => {
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
                    const singles = plain.every(([v]) => components(v).length === 1 &&
                        classify(v).includes('identifier') && own.includes(v.toLowerCase()));
                    const covered = own.every((k) => plain.some(([v]) => sameValue(v, k)));
                    if (own.length && singles && covered) {
                        chosen = {
                            kind: 'presets', group: 0, groups: 0, blocked: false,
                            fill: fill,
                            presets: plain.map(([v, r]) => [v.toLowerCase(), r.v]),
                        };
                    }
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
        if (chosen && chosen.kind !== 'unmodelled') {
            const bad = serialisation(name, chosen, longhands, plain);
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
        'pub const Kind = enum { alias, box4, box2, components, presets, unmodelled };',
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
