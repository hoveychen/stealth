// What does the bitmap store when the paint is neither an integer byte nor
// opaque?
//
// A translucent pixel goes in premultiplied and comes back out divided by its
// own alpha, and the two roundings do not cancel. That much is visible with
// plain `rgba()` (see canvas-alpha-semantics.js). This probe asks the sharper
// question: *which* colour gets premultiplied — the float the notation names, or
// the byte that float would have been stored as opaque?
//
// The wide notations are the discriminator, because their channels are not
// bytes. `color(display-p3 1 0.25 0.5)` on an srgb canvas has a blue channel of
// about 126.8: opaque it stores 127, but premultiplying the *float* by a half
// stores 63, where premultiplying the stored 127 would store 64 — and 63 of 128
// reads back one unit below 64 of 128.
(() => {
    const out = { srgb: {}, p3: {}, filter: {} };

    const hex = (d) => [...d].map((n) => n.toString(16).padStart(2, '0')).join('');
    const ask = (fn) => {
        try {
            return fn();
        } catch (e) {
            return 'threw: ' + String((e && e.message) || e).slice(0, 120);
        }
    };

    // One fill on a fresh 1x1 canvas of `space`, read back in that same space.
    const paint = (space, style, globalAlpha) => ask(() => {
        const c = new OffscreenCanvas(1, 1).getContext('2d', {
            colorSpace: space,
            willReadFrequently: true,
        });
        if (globalAlpha !== undefined) c.globalAlpha = globalAlpha;
        c.fillStyle = style;
        const read = c.fillStyle;
        c.fillRect(0, 0, 1, 1);
        return hex(c.getImageData(0, 0, 1, 1, { colorSpace: space }).data) + ' fillStyle=' + read;
    });

    // The pair that separates "premultiply the float" from "premultiply the
    // byte": same notation, opaque and at half alpha.
    for (const style of [
        'color(display-p3 1 0.25 0.5)',
        'color(display-p3 1 0.25 0.5 / 0.5)',
        'color(display-p3 1 0.25 0.5 / 0.25)',
        'color(rec2020 1 0.25 0.5 / 0.5)',
        'lab(50% 40 30)',
        'lab(50 40 30 / 0.5)',
        'oklch(0.7 0.1 20)',
        'oklch(0.7 0.1 20 / 0.5)',
        // A notation whose channels *are* bytes, for contrast.
        'rgba(255, 27, 127, 0.5)',
        // And a legacy notation whose float channels are not: hsl() lands on
        // 163.2, 102, 40.8 before it is rounded to a byte.
        '#a36629',
        'hsl(30 60% 40%)',
        'hsl(30 60% 40% / 0.5)',
    ]) {
        out.srgb[style] = paint('srgb', style);
    }

    // The same colours on a display-p3 bitmap, where an sRGB notation has to be
    // converted before it is stored: does the conversion run on the float or on
    // the byte?
    for (const style of [
        '#ff0000',
        'rgba(255, 0, 0, 0.5)',
        'hsl(30 60% 40%)',
        'hsl(30 60% 40% / 0.5)',
        'color(display-p3 1 0.25 0.5)',
        'color(display-p3 1 0.25 0.5 / 0.5)',
    ]) {
        out.p3[style] = paint('display-p3', style);
    }
    out.p3['#ff0000 globalAlpha 0.5'] = paint('display-p3', '#ff0000', 0.5);
    out.p3['color(display-p3 1 0.25 0.5) globalAlpha 0.5'] =
        paint('display-p3', 'color(display-p3 1 0.25 0.5)', 0.5);

    // A filter is the other place a float colour meets an alpha: Chrome greys
    // the premultiplied bytes, which is not the same arithmetic as greying the
    // colour and premultiplying afterwards — but it may land on the same byte.
    for (const [tag, style, filter] of [
        ['opaque', '#4080c0', 'grayscale(1)'],
        ['half', 'rgba(64,128,192,0.5)', 'grayscale(1)'],
        ['half, quarter grey', 'rgba(64,128,192,0.5)', 'grayscale(0.25)'],
        ['tenth', 'rgba(64,128,192,0.1)', 'grayscale(1)'],
        ['half p3', 'color(display-p3 1 0.25 0.5 / 0.5)', 'grayscale(1)'],
    ]) {
        out.filter[tag] = ask(() => {
            const c = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
            c.filter = filter;
            c.fillStyle = style;
            c.fillRect(0, 0, 1, 1);
            return hex(c.getImageData(0, 0, 1, 1).data);
        });
    }

    return JSON.stringify(out);
})()
