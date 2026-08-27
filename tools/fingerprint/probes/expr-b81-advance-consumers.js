// The readings that sit downstream of a text advance, once the advance itself
// is known to be exact.
//
// `expr-b81-advance-snap.js` established the rule: in headed Chrome a text-only
// box's `getBoundingClientRect().width` IS the unsnapped advance sum -- equal to
// `measureText` to the last bit, and off the 1/64 grid for 4 of 7 strings, so
// the grid the plan was named for is not where a text-derived width lands.
// (`text-advance-64th-grid` P1 read 7/7 on the grid because it ran Chrome
// headless, where `serif` resolves to different metrics.)
//
// What that leaves open is everyone who reads the same box a different way.
// This probe reads them, so removing the round inside the measurement can be
// checked against each consumer rather than against the rect alone:
//
//   * the integer readings, with a fractional padding and border in the way --
//     is `offsetWidth` `round(content + padding + border)` or
//     `round(content) + padding + border`?
//   * `scrollWidth` on an overflowing child, which is a different code path
//   * an inline box's ink, and a nested one, which accumulate per child
//   * a flex item's automatic minimum size, which comes from the longest word
//   * the height, which comes from the line box rather than the advance
//   * two more sizes and one more family, so "exact" is not a claim about 16px
//     serif alone
(() => {
    const out = {};
    const mk = (style, text, parent) => {
        const el = document.createElement('div');
        el.setAttribute('style', style);
        if (text !== undefined) el.textContent = text;
        (parent || document.documentElement).appendChild(el);
        return el;
    };
    const abs = 'position:absolute;left:0;top:0;white-space:pre;';
    const read = (name, el) => {
        out[name + '.rect'] = String(el.getBoundingClientRect().width);
        out[name + '.offset'] = String(el.offsetWidth);
        out[name + '.client'] = String(el.clientWidth);
        out[name + '.scroll'] = String(el.scrollWidth);
        out[name + '.computed'] = String(getComputedStyle(el).width);
    };

    const ctx = document.createElement('canvas').getContext('2d');

    // 1. A bare advance, as the baseline for everything below.
    let el = mk(abs + 'font:16px serif', 'aaa');
    read('bare', el);
    ctx.font = '16px serif';
    out['bare.measure'] = String(ctx.measureText('aaa').width);
    el.remove();

    // 2. The same advance with a fractional padding and border on it. If the
    //    integer reading rounds the border box as a whole, offsetWidth is
    //    round(advance + 2*1.5 + 2*0.5); if it rounds the content first it is
    //    round(advance) + 4.
    el = mk(abs + 'font:16px serif;padding:0 1.5px;border:0.5px solid black;box-sizing:content-box', 'aaa');
    read('padded', el);
    el.remove();

    // 3. An overflowing child, so scrollWidth comes from the child's box.
    el = mk(abs + 'font:16px serif;width:10px;overflow:hidden');
    mk(abs + 'font:16px serif', 'aaa bbb ccc', el);
    read('overflow', el);
    el.remove();

    // 4. An inline box's own ink, and one nested inside another.
    const holder = mk(abs + 'font:16px serif');
    holder.innerHTML = '<span id="b81a">aaa</span><br><span id="b81b">aa<b id="b81c">aa</b></span>';
    read('inlineOwn', document.getElementById('b81a'));
    read('inlineOuter', document.getElementById('b81b'));
    read('inlineInner', document.getElementById('b81c'));
    holder.remove();

    // 5. A flex item's automatic minimum size: the row is far narrower than the
    //    text, so the item cannot go below its longest word.
    const row = mk(abs + 'font:16px serif;display:flex;width:10px');
    const item = mk('flex:1;min-width:auto', 'aaa bbb ccc', row);
    read('flexMin', item);
    row.remove();

    // 6. The height, from the line box.
    el = mk(abs + 'font:16px serif', 'aaa');
    out['height.rect'] = String(el.getBoundingClientRect().height);
    out['height.offset'] = String(el.offsetHeight);
    out['height.computed'] = String(getComputedStyle(el).height);
    el.remove();

    // 7. Other sizes and one other family, against their own measureText.
    for (const font of ['13px serif', '19.5px serif', '16px sans-serif', '11px monospace']) {
        el = mk(abs + 'font:' + font, 'aaa bbb');
        ctx.font = font;
        const key = font.replace(/[ .]/g, '_');
        out[key + '.rect'] = String(el.getBoundingClientRect().width);
        out[key + '.measure'] = String(ctx.measureText('aaa bbb').width);
        out[key + '.offset'] = String(el.offsetWidth);
        el.remove();
    }

    return out;
})();
