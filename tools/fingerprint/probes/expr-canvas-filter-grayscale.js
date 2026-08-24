// Ground truth for `ctx.filter = 'grayscale(n)'`: which operations it reaches,
// what coefficients it uses, and what the setter accepts.
//
// The interesting questions are (a) does it apply to a plain fill or only to
// drawImage, (b) is the luminance computed on sRGB bytes or on linearised
// light, and (c) how are percentages, out-of-range amounts and junk handled.
(() => {
    const out = { fills: [], images: [], setter: [], notes: [] };

    const px = (ctx, x, y) => {
        const d = ctx.getImageData(x || 0, y || 0, 1, 1).data;
        return [d[0], d[1], d[2], d[3]];
    };

    const fresh = (w, h) => {
        const cv = new OffscreenCanvas(w || 1, h || 1);
        return [cv, cv.getContext('2d', { willReadFrequently: true })];
    };

    // --- does the filter reach a plain fill? --------------------------------
    for (const [filter, colour] of [
        ['none', '#4080c0'],
        ['grayscale(1)', '#4080c0'],
        ['grayscale(0)', '#4080c0'],
        ['grayscale(0.5)', '#4080c0'],
        ['grayscale(50%)', '#4080c0'],
        ['grayscale(2)', '#4080c0'],
        ['grayscale(-1)', '#4080c0'],
        ['grayscale()', '#4080c0'],
        ['grayscale(1)', '#ff0000'],
        ['grayscale(1)', '#00ff00'],
        ['grayscale(1)', '#0000ff'],
        ['grayscale(1)', '#ffffff'],
        ['grayscale(1)', 'rgba(64,128,192,0.5)'],
    ]) {
        const rec = { filter, colour };
        try {
            const [, c] = fresh(1, 1);
            c.filter = filter;
            rec.read = c.filter;
            c.fillStyle = colour;
            c.fillRect(0, 0, 1, 1);
            rec.got = px(c);
        } catch (e) { rec.err = String((e && e.message) || e).slice(0, 140); }
        out.fills.push(rec);
    }

    // --- and a drawImage of a known source ----------------------------------
    // One 4x1 source with four primaries, taken under each filter.
    const [src, cs] = fresh(4, 1);
    for (const [i, colour] of ['#ff0000', '#00ff00', '#0000ff', '#4080c0'].entries()) {
        cs.fillStyle = colour;
        cs.fillRect(i, 0, 1, 1);
    }
    for (const filter of ['none', 'grayscale(1)', 'grayscale(0.5)', 'grayscale(25%)']) {
        const rec = { filter, row: [] };
        try {
            const [, c] = fresh(4, 1);
            c.filter = filter;
            c.drawImage(src, 0, 0);
            for (let i = 0; i < 4; i++) rec.row.push(px(c, i, 0));
        } catch (e) { rec.err = String((e && e.message) || e).slice(0, 140); }
        out.images.push(rec);
    }

    // --- what does the setter keep? -----------------------------------------
    for (const v of ['none', 'NONE', 'grayscale(1)', 'grayscale(100%)', 'GRAYSCALE(1)',
        ' grayscale( 1 ) ', 'grayscale(1) blur(2px)', 'grayscale', 'notafilter(1)',
        'grayscale(1', '', 'grayscale(1e0)', 'grayscale(+1)', 'grayscale(.5)']) {
        const rec = { set: v };
        try {
            const [, c] = fresh(1, 1);
            c.filter = 'grayscale(0.25)';
            c.filter = v;
            rec.read = c.filter;
            c.fillStyle = '#4080c0';
            c.fillRect(0, 0, 1, 1);
            rec.got = px(c);
        } catch (e) { rec.err = String((e && e.message) || e).slice(0, 140); }
        out.setter.push(rec);
    }

    // --- is the filter part of the saved state? -----------------------------
    try {
        const [, c] = fresh(1, 1);
        c.filter = 'grayscale(1)';
        c.save();
        c.filter = 'none';
        c.restore();
        out.savedFilter = c.filter;
    } catch (e) { out.savedFilter = 'threw'; }

    // --- and does it compose with a blend mode? -----------------------------
    try {
        const [, c] = fresh(1, 1);
        c.fillStyle = '#ff8000';
        c.fillRect(0, 0, 1, 1);
        c.filter = 'grayscale(1)';
        c.globalCompositeOperation = 'difference';
        c.fillStyle = '#4080c0';
        c.fillRect(0, 0, 1, 1);
        out.withDifference = px(c);
    } catch (e) { out.withDifference = 'threw'; }

    return JSON.stringify(out);
})()
