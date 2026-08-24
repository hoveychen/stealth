// Ground truth for globalCompositeOperation 'multiply' and 'difference': the
// exact bytes Chrome lands for every interesting (backdrop alpha, source alpha,
// globalAlpha) combination, plus the drawImage shape the widget actually uses.
//
// The point is the corners, not the easy case. Opaque-over-opaque is just the
// blend function; the informative cells are the ones where either side is
// partly transparent, because that is where the compositing formula and a
// naive "apply the blend function to the two colours" diverge.
(() => {
    const out = { cases: [], notes: [] };

    const px = (ctx) => {
        const d = ctx.getImageData(0, 0, 1, 1).data;
        return [d[0], d[1], d[2], d[3]];
    };

    // One cell: paint `back` on a fresh 1x1, then `src` under `op`.
    const cell = (tag, op, back, src, ga) => {
        const rec = { tag, op, back, src, ga };
        try {
            const cv = new OffscreenCanvas(1, 1);
            const c = cv.getContext('2d', { willReadFrequently: true });
            c.globalCompositeOperation = 'source-over';
            c.globalAlpha = 1;
            if (back) {
                c.fillStyle = back;
                c.fillRect(0, 0, 1, 1);
            }
            rec.backdrop = px(c);
            c.globalCompositeOperation = op;
            rec.opRead = c.globalCompositeOperation;
            c.globalAlpha = ga === undefined ? 1 : ga;
            c.fillStyle = src;
            c.fillRect(0, 0, 1, 1);
            rec.got = px(c);
        } catch (e) {
            rec.err = String((e && e.message) || e).slice(0, 160);
        }
        out.cases.push(rec);
        return rec;
    };

    // --- multiply -----------------------------------------------------------
    cell('mul.opaque', 'multiply', '#ff8000', '#4080c0');
    cell('mul.white-src', 'multiply', '#3366cc', '#ffffff');
    cell('mul.black-src', 'multiply', '#3366cc', '#000000');
    cell('mul.no-backdrop', 'multiply', null, '#3366cc');
    cell('mul.src-half', 'multiply', '#ff8000', 'rgba(64,128,192,0.5)');
    cell('mul.back-half', 'multiply', 'rgba(255,128,0,0.5)', '#4080c0');
    cell('mul.both-half', 'multiply', 'rgba(255,128,0,0.5)', 'rgba(64,128,192,0.5)');
    cell('mul.galpha-half', 'multiply', '#ff8000', '#4080c0', 0.5);

    // --- difference ---------------------------------------------------------
    cell('dif.opaque', 'difference', '#ff8000', '#4080c0');
    cell('dif.same', 'difference', '#3366cc', '#3366cc');
    cell('dif.white-src', 'difference', '#3366cc', '#ffffff');
    cell('dif.black-src', 'difference', '#3366cc', '#000000');
    cell('dif.no-backdrop', 'difference', null, '#3366cc');
    cell('dif.src-half', 'difference', '#ff8000', 'rgba(64,128,192,0.5)');
    cell('dif.back-half', 'difference', 'rgba(255,128,0,0.5)', '#4080c0');
    cell('dif.both-half', 'difference', 'rgba(255,128,0,0.5)', 'rgba(64,128,192,0.5)');
    cell('dif.galpha-half', 'difference', '#ff8000', '#4080c0', 0.5);

    // --- the widget's own shape: difference of a drawn surface with itself ---
    // Two 4x4 canvases; B takes A twice, the second time under 'difference',
    // so every pixel of B has to end up 000000ff whatever A held.
    try {
        const A = new OffscreenCanvas(4, 4);
        const ca = A.getContext('2d', { willReadFrequently: true });
        ca.fillStyle = '#ffffff';
        ca.fillRect(0, 0, 4, 4);
        ca.fillStyle = '#123456';
        ca.fillRect(1, 1, 2, 2);

        const B = new OffscreenCanvas(4, 4);
        const cb = B.getContext('2d', { willReadFrequently: true });
        cb.drawImage(A, 0, 0);
        cb.globalCompositeOperation = 'difference';
        cb.drawImage(A, 0, 0);
        cb.globalCompositeOperation = 'source-over';
        const d = cb.getImageData(0, 0, 4, 4).data;
        let hex = '';
        for (let i = 0; i < d.length; i++) {
            const b = d[i].toString(16);
            hex += b.length < 2 ? '0' + b : b;
        }
        out.selfDifference = hex;

        // And the 1x1 downscale of it, which is the p7 readback.
        const C = new OffscreenCanvas(1, 1);
        const cc = C.getContext('2d', { willReadFrequently: true });
        cc.drawImage(B, 0, 0, 4, 4, 0, 0, 1, 1);
        out.downscale = px(cc);
    } catch (e) {
        out.selfDifference = 'threw: ' + String((e && e.message) || e).slice(0, 120);
    }

    // --- a blend mode on a path, not a rectangle ---------------------------
    // Half-covered edge pixels are where coverage and the blend function have
    // to combine, and the rectangle path never exercises that.
    try {
        const cv = new OffscreenCanvas(8, 1);
        const c = cv.getContext('2d', { willReadFrequently: true });
        c.fillStyle = '#ff8000';
        c.fillRect(0, 0, 8, 1);
        c.globalCompositeOperation = 'difference';
        c.fillStyle = '#4080c0';
        c.beginPath();
        c.moveTo(0, 0);
        c.lineTo(4.5, 0);
        c.lineTo(4.5, 1);
        c.lineTo(0, 1);
        c.fill();
        const d = c.getImageData(0, 0, 8, 1).data;
        out.pathEdge = Array.from(d);
    } catch (e) {
        out.pathEdge = 'threw: ' + String((e && e.message) || e).slice(0, 120);
    }

    return JSON.stringify(out);
})()
