// Is the advance linear in the font size? A 200-glyph run at 26 sizes.
//
// The snap rule (ceil onto 1/64 of a device pixel, once per text node) was
// established on 16px, where a 2048-unit font makes every advance an exact
// multiple of 1/128. This sweeps the sizes either side of it with a run long
// enough that a per-glyph error of one part in a million shows up as a whole
// grid step, and reads `measureText` beside the box so the advance and the snap
// can be told apart.
//
// The answer, on headed Chrome 151 at --force-device-scale-factor=2: 24 of 26
// sizes are linear in the size to within float noise, and 8.4px is not -- its
// per-glyph advance is 0.00444px under the linear one, the same absolute offset
// 9.9px shows in expr-b81-nondyadic-sizes.js. Those two are a font-metrics gap
// rather than a grid one, and they are the reason the snap model scores 100/107
// rather than 107/107.
(() => {
    const out = {};
    const host = document.createElement('div');
    document.documentElement.appendChild(host);
    const ctx = document.createElement('canvas').getContext('2d');
    const text = 'a'.repeat(200);
    for (let i = 0; i < 26; i++) {
        const size = 6 + i * 0.4;
        const key = 's' + size.toFixed(1).replace('.', '_');
        host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font-size:' + size + 'px;font-family:serif');
        host.textContent = text;
        ctx.font = size + 'px serif';
        out[key + '.rect'] = String(host.getBoundingClientRect().width);
        out[key + '.measure'] = String(ctx.measureText(text).width);
    }
    host.remove();
    return out;
})();
