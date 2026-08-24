// The srgb <-> display-p3 transform read at full float precision.
//
// `canvas-space-matrix.js` asked the same question through whole bytes, which
// can only pin a channel to 1/255 — enough to rule two published matrices out
// (it did) and nowhere near enough to say what the third one is. A
// `rgba-float32` read hands back the *encoded float* the transform produced,
// seven significant digits of it, so nine reads recover the whole matrix.
//
// Every fill below is opaque and lands on a whole byte, so the bitmap holds an
// exactly-known value and the only arithmetic under measurement is the
// conversion on the way out.
//
//   basis    a primary of the source space, so the reading *is* one column of
//            the composed matrix, once the transfer function is undone.
//   gray     source channels equal. Both spaces are D65 with the same white,
//            so a matrix whose rows sum to one returns gray unchanged: any
//            deviation from n/255 is the transfer function's round trip, with
//            the matrix contributing nothing. This is the one measurement that
//            separates "our matrix is wrong" from "our powf is not theirs".
//   mixed    two-channel and three-channel colours, to over-constrain the fit.
//   control  the same read without a conversion, which must be exactly n/255.
//
// ANSWER. Chrome's matrix is `skcms_Matrix3x3_concat(invert(dst->toXYZD50),
// src->toXYZD50)` over `SkNamedGamut::kSRGB` (the ICC 16.16 cells) and
// `SkNamedGamut::kDisplayP3` — where `skcms_Matrix3x3_invert` does its
// arithmetic in double and stores f32, and the concat is f32 throughout. Every
// one of the nine cells was recovered from a reading that never touches a powf
// and matched that composition to at most one ULP, both directions:
//
//   srgb -> display-p3            display-p3 -> srgb
//    0.822547197  0.177678615  -0.000004828     1.224816442 -0.225114793  0.000004023
//    0.033179868  0.966723800  -0.000010076    -0.042038292  1.042147279  0.000011312
//    0.017070306  0.072381869   0.910398364    -0.019623475 -0.078635663  1.098419309
//
// Two things fall out of that shape which no D65 matrix has. The rows do not
// sum to one — `#ffffff` reads `1.0000992 0.9999619 0.9999466`, not white — and
// the blue column's top two cells are not the structural zeros the exact
// primaries give, which is why an srgb blue reads with a faint negative red.
// Both are the D50 round trip, and both are measurable in the encode's linear
// segment, which is what pins the cells exactly.
//
// One more thing the grey rows pin, which the columns cannot: the *order* the
// matrix is applied in. Skia's `matrix_3x3` is a chain of fused multiply-adds,
// innermost term first; a plain left-to-right f32 sum of the same nine cells
// lands one ULP off on one channel of every grey reading here. Only a row whose
// three inputs are equal can see that, which is why the greys are in this probe
// and not only in the sweep.
//
// With the matrix, that order, and the two transfer functions
// (`canvas-space-float-decode.js`, `canvas-space-float-sweep.js`), all 46
// readings here reproduce exactly.
(() => {
    const out = { basisToP3: {}, basisToSrgb: {}, grayToP3: {}, grayToSrgb: {}, mixedToP3: {}, mixedToSrgb: {}, control: {} };

    const ask = (fn) => {
        try {
            return fn();
        } catch (e) {
            return 'threw: ' + String((e && e.message) || e).slice(0, 120);
        }
    };

    // A fill on a canvas of `canvasSpace`, read back through `readSpace` as
    // float32. `style` is given in the canvas's own space so nothing converts
    // on the way in.
    const read = (canvasSpace, style, readSpace) => ask(() => {
        const c = new OffscreenCanvas(1, 1).getContext('2d', {
            colorSpace: canvasSpace,
            willReadFrequently: true,
        });
        c.fillStyle = style;
        c.fillRect(0, 0, 1, 1);
        const d = c.getImageData(0, 0, 1, 1, {
            colorSpace: readSpace,
            pixelFormat: 'rgba-float32',
        });
        return [...d.data].join(' ');
    });

    // p3 coordinates spell a byte exactly: n/255 lands on the byte it names.
    const p3 = (r, g, b) => `color(display-p3 ${(r / 255).toFixed(10)} ` +
        `${(g / 255).toFixed(10)} ${(b / 255).toFixed(10)})`;
    const srgb = (r, g, b) => `rgb(${r} ${g} ${b})`;

    for (const [name, rgb] of [
        ['red', [255, 0, 0]],
        ['green', [0, 255, 0]],
        ['blue', [0, 0, 255]],
        ['white', [255, 255, 255]],
    ]) {
        out.basisToP3[name] = read('srgb', srgb(...rgb), 'display-p3');
        out.basisToSrgb[name] = read('display-p3', p3(...rgb), 'srgb');
    }

    for (const n of [1, 2, 3, 4, 10, 32, 64, 128, 192, 254]) {
        out.grayToP3[n] = read('srgb', srgb(n, n, n), 'display-p3');
        out.grayToSrgb[n] = read('display-p3', p3(n, n, n), 'srgb');
    }

    for (const rgb of [
        [153, 127, 92],
        [62, 59, 249],
        [252, 182, 14],
        [200, 100, 50],
        [17, 0, 0],
        [0, 17, 0],
        [0, 0, 17],
        [255, 128, 0],
    ]) {
        const name = rgb.join(',');
        out.mixedToP3[name] = read('srgb', srgb(...rgb), 'display-p3');
        out.mixedToSrgb[name] = read('display-p3', p3(...rgb), 'srgb');
    }

    out.control.srgb = read('srgb', srgb(153, 127, 92), 'srgb');
    out.control.p3 = read('display-p3', p3(153, 127, 92), 'display-p3');

    return JSON.stringify(out);
})()
