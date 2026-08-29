// Absolute-length units through getComputedStyle, with the grid made visible.
//
// A previous reading here had Chrome at 37.7812px for 1cm and this engine at
// 37.7891, which looks like a quantisation bug until the device pixel ratio is
// on the table: the layout grid is 1/64 of a DEVICE pixel, so it is 1/64 of a
// CSS pixel at dpr 1 and 1/128 at the dpr 2 this engine claims. Comparing a
// headless Chrome at dpr 1 against this engine at dpr 2 measures the harness.
// Run the Chrome arm with --chrome-arg --force-device-scale-factor=2.
(() => {
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;visibility:hidden';
    document.documentElement.appendChild(d);
    const out = { dpr: devicePixelRatio, units: {} };
    for (const css of ['1in', '1cm', '1mm', '1pt', '1pc', '1Q', '1ex', '1ch',
        '2.6162cm', '74.16pt', '1.03in']) {
        d.style.width = css;
        const px = parseFloat(getComputedStyle(d).width);
        out.units[css] = {
            px,
            // Which grid the answer sits on: an exact multiple of 1/64 or 1/128
            // of a CSS pixel says what the engine rounded to.
            x64: Number.isInteger(px * 64) ? px * 64 : null,
            x128: Number.isInteger(px * 128) ? px * 128 : null,
        };
    }
    d.remove();
    return JSON.stringify(out, null, 1);
})()
