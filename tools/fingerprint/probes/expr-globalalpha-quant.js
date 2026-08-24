// Is globalAlpha quantised to 8 bits before it reaches the compositor?
//
// 0.5 and 128/255 are different numbers, and source-over of black over white
// separates them: 255*(1-0.5) = 127.5 rounds up, 255*(1-128/255) = 127.0 does
// not. If Chrome reports 127 the paint alpha is a byte; 128 means it is not.
(() => {
    const out = { cases: [] };

    const cell = (tag, back, src, ga, op) => {
        const rec = { tag, back, src, ga, op: op || 'source-over' };
        try {
            const cv = new OffscreenCanvas(1, 1);
            const c = cv.getContext('2d', { willReadFrequently: true });
            c.fillStyle = back;
            c.fillRect(0, 0, 1, 1);
            c.globalCompositeOperation = rec.op;
            c.globalAlpha = ga;
            rec.gaRead = c.globalAlpha;
            c.fillStyle = src;
            c.fillRect(0, 0, 1, 1);
            const d = c.getImageData(0, 0, 1, 1).data;
            rec.got = [d[0], d[1], d[2], d[3]];
        } catch (e) { rec.err = String((e && e.message) || e).slice(0, 140); }
        out.cases.push(rec);
        return rec;
    };

    // The discriminating pair: same nominal 0.5, one as globalAlpha and one as
    // the colour's own alpha. Equal readings mean both are bytes.
    cell('ga.half.black-on-white', '#ffffff', '#000000', 0.5);
    cell('rgba.half.black-on-white', '#ffffff', 'rgba(0,0,0,0.5)', 1);
    // A third of the way is not representable as a byte at all: 85/255.
    cell('ga.third.black-on-white', '#ffffff', '#000000', 1 / 3);
    cell('rgba.third.black-on-white', '#ffffff', 'rgba(0,0,0,0.3333333333333333)', 1);
    // And one just off a byte boundary either way.
    cell('ga.0p502.black-on-white', '#ffffff', '#000000', 0.502);
    cell('ga.0p498.black-on-white', '#ffffff', '#000000', 0.498);
    // Sanity: full and zero.
    cell('ga.one', '#ffffff', '#000000', 1);
    cell('ga.zero', '#ffffff', '#000000', 0);

    return JSON.stringify(out);
})()
