// Which matrices does Chrome convert a canvas bitmap between srgb and
// display-p3 with?
//
// CSS Color 4 publishes the primaries as exact fractions through XYZ D65;
// Skia carries them as the ICC-quantised XYZ *D50* matrices its
// `SkNamedGamut` holds. Composed, the two agree to about 1e-5 — invisible on
// most colours, but every colour below is one the two disagree about by a whole
// byte in at least one channel.
//
// srgb -> display-p3 is `fillStyle` on a display-p3 canvas; display-p3 -> srgb
// is the same fill read back through `getImageData({colorSpace: 'srgb'})`.
//
// ANSWER (results/canvas-space-matrix.chrome.json): **neither**. Across the 24
// colours Chrome sides with the D65 fractions 11 times, with the D50 matrices
// 12 times, and with neither once (`#997f5c` reads `4598e4`, where the two
// predict `4498e5` and `4598e5`). So Chrome's transform is a third thing, and
// swapping our matrices for either published set is not the fix.
//
// The third thing is now named, by `canvas-space-float-matrix.js`: the D50
// matrices are right, but *composed the way skcms composes them* — invert the
// destination's `toXYZD50` in double and store the result as f32, then
// concatenate with the source's in f32. Rounding the composition to f32 twice
// is what moves it off both published products; nothing about the published
// D50 cells themselves is wrong. Under that matrix these 24 read 17/24 rather
// than 11/24, and every miss left is a channel off by one, which belongs to the
// encode transfer function rather than to the matrix — see
// `canvas-space-float-sweep.js`.
(() => {
    const out = { toP3: {}, toSrgb: {} };

    const hex = (d) => [...d].map((n) => n.toString(16).padStart(2, '0')).join('');
    const ask = (fn) => {
        try {
            return fn();
        } catch (e) {
            return 'threw: ' + String((e && e.message) || e).slice(0, 120);
        }
    };

    const fill = (canvasSpace, style, readSpace) => ask(() => {
        const c = new OffscreenCanvas(1, 1).getContext('2d', {
            colorSpace: canvasSpace,
            willReadFrequently: true,
        });
        c.fillStyle = style;
        c.fillRect(0, 0, 1, 1);
        return hex(c.getImageData(0, 0, 1, 1, { colorSpace: readSpace }).data).slice(0, 6);
    });

    // An srgb hex on a display-p3 bitmap: the conversion runs on the way in.
    for (const style of [
        '#997f5c',
        '#3e3bf9',
        '#fcb60e',
        '#2b3dc6',
        '#3e4fbb',
        '#6547cf',
        '#a6fd4c',
        '#a900a6',
        '#4180df',
        '#059aeb',
        '#8374d9',
        '#1686a2',
    ]) {
        out.toP3[style] = fill('display-p3', style, 'display-p3');
    }

    // A display-p3 notation stored verbatim on a display-p3 bitmap, then read
    // back as srgb: the conversion runs on the way out. The channels are the
    // hex above read as p3 coordinates.
    for (const style of [
        '#7d7633',
        '#f2cc36',
        '#bc4ab8',
        '#1b01b5',
        '#9b36b6',
        '#9918f4',
        '#3fab86',
        '#9018bc',
        '#62889a',
        '#08bdaf',
        '#00a486',
        '#9e1dca',
    ]) {
        const n = (at) => (parseInt(style.slice(1 + at * 2, 3 + at * 2), 16) / 255).toFixed(8);
        out.toSrgb[style] = fill(
            'display-p3',
            `color(display-p3 ${n(0)} ${n(1)} ${n(2)})`,
            'srgb',
        );
    }

    return JSON.stringify(out);
})()
