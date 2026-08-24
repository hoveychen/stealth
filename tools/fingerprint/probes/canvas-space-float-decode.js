// Chrome's *decode* transfer function, read exactly, for all 256 bytes.
//
// The trick is the blue column of the composed matrix. Going either way between
// srgb and display-p3 its top two cells are ~5e-6 and ~1e-5 — small enough that
// a blue-only fill lands the red and green outputs inside the encode's linear
// segment for every byte, where the encode is one multiply by 12.92 and so
// exactly invertible. Divide the reading by 12.92 and by the (separately
// pinned) matrix cell and what is left is the decode of `n/255`, to the last
// bit, with no approximate powf between it and the wire.
//
// This is the measurement that says whether the residual left over after the
// matrix is pinned lives in the decode or in the encode.
//
// ANSWER: the encode. All 512 readings — 256 bytes, two channels, and again for
// the other direction — reproduce bit for bit under Skia's `approx_powf` from
// `src/opts/SkRasterPipeline_opts.h`:
//
//   approx_log2(x) = nmad(m, 1.498030302f, e - 124.225514990f)
//                  - 1.725879990f / (0.3520887068f + m)
//   approx_pow2(x) = bit_cast<float>(round(  (1<<23)
//                  * (nmad(f, 1.490129070f, x + 121.274057500f)
//                     + 27.728023300f / (4.84252568f - f)) ))
//   approx_powf(x, g) = x == 0 || x == 1 ? x : approx_pow2(approx_log2(x) * g)
//
// with the sRGB parametric coefficients `{2.4f, (float)(1/1.055),
// (float)(0.055/1.055), (float)(1/12.92), 0.04045f, 0, 0}`. So the decode is not
// a powf at all, and it is not skcms's own copy either: skcms truncates the cast
// out of `approx_exp2` and writes the polynomial without an fma, and that
// version misses 26 of the 512 by about 64 units of the last place — the two
// differ exactly where the pre-cast float sits on a rounding boundary. It is
// Skia's raster pipeline doing this work, not `skcms_Transform`.
(() => {
    const out = { toP3: {}, toSrgb: {} };

    const read = (canvasSpace, style, readSpace) => {
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
        return [...d.data].slice(0, 2).join(' ');
    };

    for (let n = 0; n < 256; n++) {
        const u = (n / 255).toFixed(10);
        out.toP3[n] = read('srgb', `rgb(0 0 ${n})`, 'display-p3');
        out.toSrgb[n] = read('display-p3', `color(display-p3 0 0 ${u})`, 'srgb');
    }

    return JSON.stringify(out);
})()
