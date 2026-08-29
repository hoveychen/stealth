// `ex` and `ch` across families and sizes, with the em-ratio made explicit.
//
// This engine computes both as a flat 0. The spec fallbacks are 0.5em for `ex`
// and 0.5em for `ch`, but a real browser uses the font's x-height and the
// advance of "0" -- so the question a fix has to answer first is whether the
// ratio is per-family (a table is needed) or constant (it is not). Ratios are
// reported rather than pixels so the two are distinguishable at a glance.
//
// Run the Chrome arm with --chrome-arg --force-device-scale-factor=2 so the
// layout grid matches this engine's persona.
(() => {
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;visibility:hidden';
    document.documentElement.appendChild(d);

    const out = { dpr: devicePixelRatio, rows: {} };
    const FAMILIES = ['serif', 'sans-serif', 'monospace', 'Arial', 'Times New Roman',
        'Courier New', 'Georgia', 'Verdana', 'Helvetica'];
    const SIZES = [10, 16, 32];

    for (const fam of FAMILIES) {
        for (const size of SIZES) {
            d.style.font = `${size}px "${fam}"`;
            const cs = getComputedStyle(d);
            // The family the engine actually resolved to, so a missing font is
            // not read as a different metric.
            const resolved = cs.fontFamily;
            d.style.width = '10ex';
            const ex = parseFloat(getComputedStyle(d).width) / 10;
            d.style.width = '10ch';
            const ch = parseFloat(getComputedStyle(d).width) / 10;
            d.style.width = 'auto';
            out.rows[`${fam}@${size}`] = {
                resolved,
                ex, ch,
                exEm: +(ex / size).toFixed(5),
                chEm: +(ch / size).toFixed(5),
            };
        }
    }
    d.remove();
    return JSON.stringify(out, null, 1);
})()
