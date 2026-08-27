// Does the advance itself survive a font size that is not a power-of-two
// fraction?
//
// The snap is settled: ceil onto 1/64 of a device pixel, once per text node. It
// is a ceil, which makes it maximally sensitive to the last bit of the number
// being snapped -- a value a hair above a step goes up a whole step. At 16px
// with a 2048-unit font every advance is an exact multiple of 1/128 and there is
// no last bit to argue about; at 13.3px there is, because Blink accumulates the
// pen in a 32-bit float per glyph while this engine sums integer font units and
// scales once.
//
// The sizes here are the ones where those two differ, and each is read on both
// arms as `rect` (after the snap) and `measureText` (before it), so the question
// splits cleanly: does the advance already differ, and if it does, does the ceil
// hide it or amplify it?
(() => {
    const out = {};
    const host = document.createElement('div');
    document.documentElement.appendChild(host);
    const ctx = document.createElement('canvas').getContext('2d');

    const strings = { a: 'a', a3: 'aaa', mix: 'aaa bbb ccc', long: 'long word '.repeat(10), k: 'a'.repeat(200) };
    // Sizes that are not dyadic rationals, so units*size/2048 is inexact.
    for (const size of [13.3, 12.1, 17.7, 21.3, 9.9, 11.11, 15.3, 19.9]) {
        for (const [name, text] of Object.entries(strings)) {
            const font = size + 'px serif';
            host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font-size:' + size + 'px;font-family:serif');
            host.textContent = text;
            ctx.font = font;
            const key = String(size).replace('.', '_') + '.' + name;
            out[key + '.rect'] = String(host.getBoundingClientRect().width);
            out[key + '.measure'] = String(ctx.measureText(text).width);
        }
    }
    host.remove();
    return out;
})();
