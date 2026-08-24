// Chrome's srgb <-> display-p3 encode transfer function, sampled densely.
//
// `canvas-space-float-matrix.js` pinned the matrix: the six off-diagonal cells
// and the three row sums all come back through the transfer function's *linear*
// segment, where the arithmetic is one multiply, so they are readable exactly.
// What is left over is the encode on the way out, and this sweep measures it.
//
// A gray fill is the right stimulus: both spaces share a white point, so the
// matrix contributes only its row sum, which is known. Every byte therefore
// hands back three samples of the encode at an argument computed exactly, and
// 256 bytes cover the whole range.
//
// WHAT IT SAYS, AND WHAT IT DOES NOT. It is one scalar function: the nine basis
// readings in `canvas-space-float-matrix.js` land on this curve to within its
// own interpolation error, and both directions interleave without a seam, so
// the encode does not depend on which way the conversion runs or on what shape
// the fill had. Against that curve:
//
//   textbook   1.055*y^(1/2.4) - 0.055   sits about 3.5e-5 low, everywhere
//   Skia       approx_powf(1.1371191*y, 0.41666666) - 0.055   sits lower still
//   power law  best A*y^G + E fit over the 1470 samples: rms 1.4e-5, so no
//
// ANSWER: it is Skia's `approx_powf` after all — with `a` = 1.1372833, which is
// what skcms's *own* approximate pow answers for `1.055^2.4` rather than the
// exact 1.1371191 — and a constant term that is not -0.055.
//
// What names it is the shape of the residual, not its size. Subtract the
// textbook curve and the miss is 3.022e-5 at *every* sample in the nonlinear
// segment, from a reading of 0.043 to one of 1.0, and exactly zero in the
// linear one. A pow that is off is off proportionally; only a constant term is
// off by a constant. So the whole discrepancy is the `+ e` of the parametric
// stage, and solving for it gives a single f32: -0.05496978759765625, which is
// `1 - approx_powf(1.1372833, 1/2.4)`.
//
// That is `skcms_TransferFunction_invert`'s last paragraph, in
// modules/skcms/skcms.cc — after inverting each coefficient it bends `e` (or
// `f`, whichever segment holds it) so that "the valuable invariant
// `inv(src(1.0f)) == 1.0f`" survives the approximation. Chrome's encode is
// therefore *not* its decode inverted: it is the inverse tilted by 3.02e-5 to
// keep white exactly white. Under it every one of these 1536 channels is exact,
// both directions, where the textbook curve missed all 1470 in the nonlinear
// segment by the same amount.
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
        return [...d.data].slice(0, 3).join(' ');
    };

    for (let n = 0; n < 256; n++) {
        const u = (n / 255).toFixed(10);
        out.toP3[n] = read('srgb', `rgb(${n} ${n} ${n})`, 'display-p3');
        out.toSrgb[n] = read('display-p3', `color(display-p3 ${u} ${u} ${u})`, 'srgb');
    }

    return JSON.stringify(out);
})()
