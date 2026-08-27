// Where the grid is, and how often the advance meets it.
//
// `expr-b81-advance-consumers.js` turned up a rule that fits every headed-Chrome
// reading taken so far: a text-derived width is `round(advance * 128) / 128`.
// Every one of twelve rects is a multiple of 1/128 and four are not multiples of
// 1/64, so the grid the parent plan measured for *specified* lengths is not the
// one a text advance lands on. At 16px with a 2048-unit font the exact advance
// is already a multiple of 1/128 (16/2048 = 1/128), which is why the rule was
// invisible there; 13px, 19.5px and 11px separate it.
//
// Two things are still open, and both decide where the snap goes in the code:
//
//   1. Is the grid 1/128, or something finer that 1/128 happens to fit? 1/256 is
//      already ruled out at 13px (it lands a step below Chrome). Sizes are swept
//      here so the answer does not rest on three readings.
//   2. Is the snap once per box, or once per glyph, or once per text node? At
//      13px `a` alone quantises up by 1/512, so three of them differ by 1/128
//      between a per-glyph snap (17.3203125) and a per-box one (17.3125). Two
//      text nodes in one element separate the third case.
//
// Chrome must be run `--headed`: headless resolves `serif` to different metrics
// and every number here moves.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre');
    document.documentElement.appendChild(host);
    const ctx = document.createElement('canvas').getContext('2d');

    const read = (key, font, build) => {
        host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font:' + font);
        while (host.firstChild) host.removeChild(host.firstChild);
        const text = build(host);
        ctx.font = font;
        out[key + '.rect'] = String(host.getBoundingClientRect().width);
        out[key + '.measure'] = String(ctx.measureText(text).width);
    };
    const one = (text) => (el) => { el.appendChild(document.createTextNode(text)); return text; };

    // 1. A size sweep, one string, so the grid can be read off many residues.
    for (const size of [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 24, 32, 12.5, 13.25, 15.75, 21.3]) {
        read('s' + String(size).replace('.', '_'), size + 'px serif', one('aaa bbb ccc'));
    }

    // 2. Per-glyph vs per-box vs per-node, at 13px where they differ.
    read('g1', '13px serif', one('a'));
    read('g2', '13px serif', one('aa'));
    read('g3', '13px serif', one('aaa'));
    // Same three characters, split across three text nodes.
    read('g3split', '13px serif', (el) => {
        el.appendChild(document.createTextNode('a'));
        el.appendChild(document.createTextNode('a'));
        el.appendChild(document.createTextNode('a'));
        return 'aaa';
    });
    // And across two nodes with the split off a glyph boundary of the string.
    read('g5split', '13px serif', (el) => {
        el.appendChild(document.createTextNode('aa'));
        el.appendChild(document.createTextNode('aaa'));
        return 'aaaaa';
    });
    read('g5', '13px serif', one('aaaaa'));

    // 3. The same question one more time at a size whose exact advance is a long
    //    way off any grid, so a per-glyph snap accumulates visibly.
    for (const n of [1, 2, 3, 5, 10, 20]) {
        read('r' + n, '13.25px serif', one('a'.repeat(n)));
    }

    host.remove();
    return out;
})();
