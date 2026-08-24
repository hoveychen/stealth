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
// It is an approximation — dividing the readings by Skia's `approx_powf` leaves
// a residual five times smoother than dividing by an exact powf, which is that
// polynomial's own oscillation cancelling — but not one of the shapes above.
// Whatever it is, the error it costs is about 3.5e-5 in the encoded float,
// which is 0.009 of a byte, so it only ever moves a reading that already sits
// within a hundredth of a rounding boundary. 1470 samples are archived in
// results/ for whoever names it.
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
