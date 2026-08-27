// Does the layout still keep a 32-bit float once the grid is 1/128?
//
// The parent plan `layout-unit-64th-grid` established two things about a
// specified length: it floors onto the grid, and the number it floors is the
// value narrowed to a 32-bit float rather than the double the author wrote
// (`width:100.0156249px` is a hair under a 1/64 step as a double and IS the step
// as a float, and Chrome answers the step). Both were measured at a device scale
// factor of 1 -- and the grid has since turned out to be 1/64 of a DEVICE pixel,
// so at 2x the step is 1/128 and every case that separated the two models at
// 1/64 lands somewhere else.
//
// These cases separate them at 1/128: each is a hair BELOW a 1/128 step by less
// than half a float step, so the double floors to the step beneath and the
// float IS the step. `wantF32` and `wantF64` are what each model predicts, so
// the reading names the winner without arithmetic afterwards.
(() => {
    const host = document.createElement('div');
    document.body.appendChild(host);
    const read = (decl) => {
        const w = document.createElement('div');
        w.innerHTML = '<div style="width:1000px"><div data-m style="width:' + decl + 'px">x</div></div>';
        host.appendChild(w);
        const el = w.querySelector('[data-m]');
        const out = { rect: String(el.getBoundingClientRect().width), css: getComputedStyle(el).width };
        w.remove();
        return out;
    };
    const f32 = (x) => Math.fround(x);
    const out = { dpr: String(window.devicePixelRatio) };
    // Steps on the 1/128 grid, each approached from just below.
    const decls = [
        '100.00781249', '100.0078124', '250.00781249', '64.00781249',
        '12.35156249', '7.00781249', '512.00781249', '3.99218749',
        '199.99218749', '33.33593749',
        // And the parent plan's own two, whose separation was at 1/64.
        '100.0156249', '465.5466592',
    ];
    for (const d of decls) {
        const r = read(d);
        const x = Number(d);
        out[d + '.rect'] = r.rect;
        out[d + '.css'] = r.css;
        for (const [g, name] of [[64, 'g64'], [128, 'g128']]) {
            out[d + '.' + name + 'F64'] = String(Math.floor(x * g) / g);
            out[d + '.' + name + 'F32'] = String(Math.floor(f32(x) * g) / g);
        }
    }
    host.remove();
    return out;
})();
