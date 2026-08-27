// Which way a text advance is quantised on its way into the box.
//
// `text-advance-64th-grid` P1 established the two ends: Chrome's
// `getBoundingClientRect().width` for a text-only box lands on the 1/64px grid
// (7/7), and this engine answers the whole number `round()` of it. What P1 did
// not read is the number *before* the snap, so the snap itself -- floor, round
// or ceil onto the grid, and whether it happens once per box or once per run --
// is still a guess.
//
// `measureText` is that number: an unsnapped advance, in both engines, for the
// same family and size the box uses. Reading the pair on one page makes the
// rule derivable rather than assumed:
//
//   rect === floor(measure * 64) / 64   -- the rule `layoutUnit` already has
//   rect === round(measure * 64) / 64
//   rect === ceil(measure * 64) / 64
//
// The three candidates are evaluated here for Chrome's own pair, so the answer
// arrives with the reading instead of being inferred from it afterwards. Run
// Chrome `--headed`: which font `serif` resolves to is the window system's
// answer, and a headless Chrome need not give the same one.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font:16px serif');
    document.documentElement.appendChild(host);

    const ctx = document.createElement('canvas').getContext('2d');
    ctx.font = '16px serif';

    const strings = {
        one: 'aaa',
        word: 'word',
        two: 'aaa bbb',
        three: 'aaa bbb ccc',
        five: 'five words in a row',
        long: 'long word '.repeat(10),
        thousand: 'a'.repeat(1000),
        // A single glyph, so a per-glyph snap and a per-box snap cannot hide in
        // each other's rounding.
        single: 'a',
        pair: 'aa',
        // Kerned in the reference: whether the box sees the kerning the canvas
        // does is part of "is it the same number".
        kern: 'AV',
        space: ' ',
    };

    const grid = (n, f) => String(f(n * 64) / 64);

    for (const [name, text] of Object.entries(strings)) {
        host.textContent = text;
        const rect = host.getBoundingClientRect().width;
        const adv = ctx.measureText(text).width;
        out[name + '.rect'] = String(rect);
        out[name + '.measure'] = String(adv);
        out[name + '.floor'] = grid(adv, Math.floor);
        out[name + '.round'] = grid(adv, Math.round);
        out[name + '.ceil'] = grid(adv, Math.ceil);
        // Which of the three reproduces the rect, said outright.
        const hits = [];
        if (grid(adv, Math.floor) === String(rect)) hits.push('floor');
        if (grid(adv, Math.round) === String(rect)) hits.push('round');
        if (grid(adv, Math.ceil) === String(rect)) hits.push('ceil');
        out[name + '.hit'] = hits.join(',') || 'none';
    }

    // Which family `serif` actually resolved to, on each arm, so a mismatch in
    // the advance can be told apart from a mismatch in the snap.
    out['font.computed'] = getComputedStyle(host).fontFamily;
    out['font.canvas'] = ctx.font;

    host.remove();
    return out;
})();
