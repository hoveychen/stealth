// This engine has two answers for a declaration: keep it as written, or
// rewrite it. It has no third one. Chrome has -- it throws the declaration
// away, and `probe-css16.js` left 46 readings whose whole difference was that.
//
// This asks what "throw away" means, in the four directions the answer could
// go: how much goes (the one longhand, the whole shorthand, or the whole
// declaration), which values are out of range and per which property (the
// negatives, since `accepts()` classifies `-10px` as a length and stops), what
// happens to a component count or a keyword the grammar does not take, and
// what the object looks like afterwards -- `length`, `item(i)`,
// `getPropertyValue`, `cssText`.
//
// The sequences are the load-bearing half: a rejected declaration on a fresh
// element and a rejected declaration over a good one look identical if all you
// read is `length`.
//
// What it said, over 525 readings on headed Chrome 151 (243 of which this
// engine already matches):
//
//   * **The unit of refusal is the declaration, and refusing is not a write.**
//     `margin: 10px bogus` stores nothing at all -- not `margin-top: 10px` and
//     three refusals, nothing -- and over an existing `margin: 5px` the object
//     still reads `5px` afterwards, byte for byte. So the check has to run
//     before the store is touched, never as a per-longhand filter during it.
//     Inside a `cssText` block each declaration is judged alone: `color: red;
//     margin: bogus; padding: 5px` keeps the colour and the padding.
//   * **The sign rule and the percentage rule are two independent per-property
//     bits, and neither implies the other.** `padding`, `width`, the radius and
//     border-width families, `gap`, `flex-basis`, `line-height`, `font-size`
//     and `perspective` refuse a negative; `margin`, the inset family,
//     `letter-spacing`, `word-spacing`, `text-indent`, `vertical-align`,
//     `background-position` and `text-underline-offset` take one. Separately,
//     `border-width`, `outline-width`, `column-width`, `border-spacing`,
//     `perspective` and `outline-offset` refuse a percentage of either sign.
//     `outline-offset` is the property that proves the two are orthogonal: it
//     takes `-10px` and refuses `10%`.
//   * **The test is on the number, not on the leading `-`.** `padding: -0px`
//     is accepted and reads back `0px`, sign dropped, and so is `flex-grow:
//     -0`. `column-count: -0`, `font-weight: -0` and `widows: -0` are refused,
//     because those want >= 1 and -0 is 0. A lexical check gets all six wrong.
//   * **Ranges are real and they are not all "non-negative".** `font-weight`
//     is [1,1000] and takes `399.5`; `column-count`, `widows` and `orphans`
//     want a positive integer; `z-index` and `order` want an integer of either
//     sign (`1.5` refused, `-1` fine); `transition-duration` wants a
//     non-negative time and refuses a unitless `1`; `rotate` refuses a
//     unitless `90`. `opacity: -1` and `opacity: 2` are both *accepted* --
//     that one clamps later rather than refusing, which is the distinction a
//     range table has to encode.
//   * **Arity is fatal, not truncating.** Five components on a box, three on a
//     `gap` or a `background-position`, two on any longhand -- all refused
//     whole. So is a longhand handed a shorthand's shape (`margin-top: 1px
//     2px`, `border-top-left-radius: 1px / 2px`).
//   * **A CSS-wide keyword is a whole-declaration value.** `margin: initial`
//     is fine; `margin: 10px inherit` and `inherit 10px` are refused. And a
//     keyword is per-longhand: `margin: 10px auto` is fine where `padding:
//     10px auto` is not.
//   * Refused too: an unknown property, `!important` inside a `setProperty`
//     value, and any value carrying a `;` or a `}`.
//
// Of the 282 readings that differ, 264 are this one gap -- 246 where Chrome
// refuses and this engine keeps, 18 more where the residue of a refusal that
// never happened is what differs. The other 18 are unrelated and stay after
// it: `transform-origin: 10px` filling to `10px center` (6), `column-gap` and
// `row-gap` serialising under their `grid-*` alias (6), `opacity: 50%`
// becoming `0.5` (2), `aspect-ratio: 1` filling to `1 / 1` (2), a comment
// inside a value being stripped (1), and an `!important` declaration sorting
// last in `cssText` (1).
(() => {
    const out = {};

    // One declaration on a fresh element. The reading is the whole object, so
    // a refusal shows up as length 0 rather than as a changed string.
    const one = (property, value) => {
        const el = document.createElement('div');
        let threw = '';
        try {
            el.style.setProperty(property, value);
        } catch (e) {
            threw = String(e && e.name);
        }
        const names = [];
        for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
        out[`${property}: ${value}`] = {
            items: names,
            values: names.map((n) => el.style.getPropertyValue(n)),
            read: el.style.getPropertyValue(property),
            cssText: el.style.cssText,
            threw: threw,
        };
    };

    // Steps in order, then read. `probe` is what to read back at the end --
    // the whole object goes in either way, so a clobber shows either as a
    // changed value or as a shrunken `length`.
    const seq = (label, steps, probe) => {
        const el = document.createElement('div');
        for (const [property, value] of steps) {
            try {
                el.style.setProperty(property, value);
            } catch (e) { /* recorded by `one` for the same value */ }
        }
        const names = [];
        for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
        out[`seq ${label}`] = {
            items: names,
            values: names.map((n) => el.style.getPropertyValue(n)),
            read: el.style.getPropertyValue(probe),
            cssText: el.style.cssText,
            threw: '',
        };
    };

    // A whole declaration block at once. Whether one bad declaration takes the
    // block's good ones with it is a different question from whether one bad
    // component takes a shorthand's good ones.
    const text = (css) => {
        const el = document.createElement('div');
        let threw = '';
        try {
            el.style.cssText = css;
        } catch (e) {
            threw = String(e && e.name);
        }
        const names = [];
        for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
        out[`cssText ${css}`] = {
            items: names,
            values: names.map((n) => el.style.getPropertyValue(n)),
            read: '',
            cssText: el.style.cssText,
            threw: threw,
        };
    };

    // ---- the negatives, by property ----------------------------------------
    // `-10px` classifies as a length everywhere, so the rule cannot be a value
    // rule. It has to be a per-property one, and it has to be measured: margin
    // takes it, padding does not, and no amount of staring at either grammar
    // tells you which side `letter-spacing` or `flex-basis` is on.
    // `10%` is in here to keep the sign apart from the unit: without it, a
    // property that refuses `-10%` and takes `-10px` looks like a sign rule
    // when it is a percentage rule. `outline-offset` is exactly that property.
    const negatives = ['-10px', '-10%', '10%', '-0.5em', '0px', '10px'];
    const lengthProperties = [
        // Expected to take one, on the "it is an offset" reading.
        'margin', 'margin-top', 'margin-inline-start',
        'top', 'left', 'inset', 'inset-block-start',
        'letter-spacing', 'word-spacing', 'text-indent', 'outline-offset',
        'vertical-align', 'background-position', 'transform-origin',
        // Expected to refuse one, on the "it is a size" reading.
        'padding', 'padding-top', 'padding-inline-start',
        'width', 'height', 'min-width', 'max-height',
        'border-width', 'border-top-width', 'outline-width', 'column-width',
        'border-radius', 'border-top-left-radius', 'border-start-start-radius',
        'flex-basis', 'gap', 'column-gap', 'row-gap', 'border-spacing',
        'line-height', 'font-size', 'text-underline-offset', 'perspective',
    ];
    for (const property of lengthProperties) {
        for (const value of negatives) one(property, value);
    }

    // ---- the numbers, where the range is not about the sign ----------------
    // `font-weight: 1001` and `opacity: -1` separate two rules that look like
    // one: refused at parse, versus taken and clamped later. A model that
    // refuses on range needs to know which properties do neither.
    const numeric = [
        ['z-index', ['-1', '0', '1', '1.5', 'auto']],
        ['order', ['-1', '0', '1', '1.5']],
        ['opacity', ['-1', '0', '0.5', '1', '2', '50%', '-10%']],
        ['flex-grow', ['-1', '0', '1', '1.5']],
        ['flex-shrink', ['-1', '0', '2']],
        ['font-weight', ['0', '1', '100', '400', '1000', '1001', '399.5', '-400', 'bold']],
        ['line-height', ['-1', '0', '1.5', 'normal']],
        ['column-count', ['-1', '0', '1', '2.5', 'auto']],
        ['widows', ['-1', '0', '2', '2.5']],
        ['orphans', ['0', '2']],
        ['tab-size', ['-1', '0', '4', '4.5', '-4px', '4px']],
        ['transition-duration', ['-1s', '0s', '1s', '1', '-0ms']],
        ['animation-duration', ['-1s', '0s', '1s']],
        ['animation-iteration-count', ['-1', '0', '2', 'infinite']],
        ['animation-delay', ['-1s', '0s', '1s']],
        ['scale', ['-1', '0', '1', '1 2']],
        ['aspect-ratio', ['-1', '0', '1', '16 / 9', '16 / -9', 'auto']],
        ['rotate', ['-90deg', '0deg', '90deg', '90']],
        ['stroke-width', ['-1px', '0', '1px']],
        ['font-size-adjust', ['-1', '0.5', 'none']],
    ];
    for (const [property, values] of numeric) {
        for (const value of values) one(property, value);
    }

    // Negative zero is not negative, and `transition-duration: -0ms` already
    // says so for a time. An implementation that refuses on the leading `-`
    // rather than on the number gets every one of these wrong.
    for (const property of ['padding', 'width', 'border-radius', 'font-size',
        'gap', 'border-width', 'padding-top']) {
        one(property, '-0px');
        one(property, '-0%');
    }
    for (const property of ['flex-grow', 'column-count', 'font-weight', 'widows']) {
        one(property, '-0');
    }

    // ---- too many components, and the wrong shape --------------------------
    // A box takes at most four, a gap at most two, a longhand exactly one.
    // Feeding each one more than it takes says whether the surplus is ignored
    // or fatal, and feeding a longhand a shorthand-shaped value says whether
    // the longhand parser is the shorthand's with a narrower table or a
    // different one.
    const boxes = ['margin', 'padding', 'border-width', 'border-color',
        'border-style', 'inset', 'border-radius', 'scroll-margin'];
    for (const property of boxes) {
        one(property, '1px 2px 3px 4px');
        one(property, '1px 2px 3px 4px 5px');
        one(property, '1px 2px 3px 4px 5px 6px');
    }
    const pairs = ['gap', 'border-spacing', 'background-position', 'overflow',
        'place-items', 'inset-inline'];
    for (const property of pairs) {
        one(property, '1px');
        one(property, '1px 2px');
        one(property, '1px 2px 3px');
    }
    const longhands = ['margin-top', 'padding-left', 'width', 'border-top-width',
        'border-top-left-radius', 'color', 'font-size', 'z-index', 'flex-basis'];
    for (const property of longhands) {
        one(property, '1px 2px');
        one(property, '1px / 2px');
        one(property, '1px,2px');
    }

    // ---- keywords where the grammar has none ------------------------------
    // `auto` is the sharpest of these: valid on margin and width, not on
    // padding or a radius, and `accepts()` has an empty keyword list for a
    // corner, so it already refuses one there. Whether the *whole declaration*
    // goes is the part this measures.
    const keywordTargets = ['margin', 'margin-top', 'padding', 'padding-top',
        'width', 'height', 'border-radius', 'border-top-left-radius',
        'border-width', 'gap', 'line-height', 'font-size', 'flex-basis', 'inset'];
    for (const property of keywordTargets) {
        one(property, 'auto');
        one(property, 'none');
        one(property, 'normal');
        one(property, 'bogus');
        one(property, '10');
        one(property, '10foo');
    }

    // A CSS-wide keyword is a whole-declaration value, so mixing one into a
    // list is a different refusal from a misspelling.
    one('margin', '10px auto');
    one('padding', '10px auto');
    one('margin', '10px inherit');
    one('margin', 'inherit 10px');
    one('border-width', '1px 2px medium');
    one('border-width', 'medium thick thin 1px');
    one('margin', 'initial');
    one('margin', '10px !important');
    one('margin', '');
    one('margin', ' ');
    one('margin', '10px;');
    one('margin', '10px}');
    one('margin', '10px /* c */ 20px');
    one('margin', '10px 20px;color:red');
    one('bogus-property', '10px');
    one('--custom', '10px 20px 30px 40px 50px');
    one('--custom', 'anything at all !');

    // ---- the sequences: does a refusal clobber? ---------------------------
    seq('good then bad shorthand', [['margin', '5px'], ['margin', 'bogus']], 'margin');
    seq('good then bad component', [['margin', '5px'], ['margin', '10px bogus']], 'margin');
    seq('good then overlong', [['margin', '5px'], ['margin', '1px 2px 3px 4px 5px']], 'margin');
    seq('good then negative', [['padding', '5px'], ['padding', '-10px']], 'padding');
    seq('shorthand then bad longhand', [['margin', '5px'], ['margin-top', 'bogus']], 'margin');
    seq('longhand then bad shorthand', [['margin-top', '5px'], ['margin', '1px 2px 3px 4px 5px']], 'margin-top');
    seq('bad then good', [['margin', 'bogus'], ['margin', '5px']], 'margin');
    seq('bad shorthand only', [['margin', 'bogus']], 'margin');
    seq('four then bad radius', [['border-radius', '1px 2px 3px 4px'], ['border-radius', '-1px']], 'border-radius');
    seq('radius corner then slash', [['border-top-left-radius', '5px'], ['border-top-left-radius', '1px / 2px']], 'border-top-left-radius');
    seq('two props one bad', [['color', 'red'], ['margin', 'bogus'], ['padding', '5px']], 'color');
    seq('remove after refusal', [['margin', 'bogus'], ['margin', '5px'], ['margin', 'bogus']], 'margin');
    seq('bad longhand alone', [['margin-top', 'bogus']], 'margin-top');
    seq('good longhand then bad same', [['margin-top', '5px'], ['margin-top', '-10px']], 'margin-top');
    seq('padding longhand then bad', [['padding-top', '5px'], ['padding-top', '-10px']], 'padding-top');

    // ---- a whole block at once --------------------------------------------
    text('margin: 5px');
    text('margin: bogus');
    text('color: red; margin: bogus; padding: 5px');
    text('color: red; margin: 10px bogus; padding: 5px');
    text('color: red; margin: -10px; padding: -5px');
    text('margin: 5px; margin: bogus');
    text('border-radius: 1px 2px 3px 4px 5px; color: red');
    text('border-radius: -1px; color: red');
    text('margin: 10px; bogus-property: 1; padding: 2px');
    text('margin: 10px !important; padding: 2px');
    text('margin');
    text('margin:');
    text('color: red; ; padding: 2px');

    return out;
})()
