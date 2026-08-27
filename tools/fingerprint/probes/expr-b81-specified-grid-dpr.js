// Is the grid a SPECIFIED length lands on device-scaled too?
//
// The text-advance grid turned out to be 1/64 of a *device* pixel: the same
// 30-case probe answers `ceil(advance*64)/64` under
// `--force-device-scale-factor=1` and `ceil(advance*128)/128` under `=2`, and 14
// of the 30 differ. The parent plan `layout-unit-64th-grid` measured specified
// and percentage lengths onto a 1/64 CSS-pixel grid reached by FLOOR
// (`width:33.3%` of 400px is 133.1875 = 8524/64) -- and if that reading was
// taken at a device scale factor of 1, it is a reading of the same
// device-pixel grid seen at 1x, which would mean this engine, whose
// devicePixelRatio is 2, should be flooring onto 1/128 instead.
//
// The same cases the parent plan's test asserts are read here, so running this
// once at each scale factor answers it outright. Nothing here depends on fonts,
// so headless would do; it is run headed for the same reason the advance probes
// are -- one arm, one set of conditions.
(() => {
    const out = {};
    out['dpr'] = String(window.devicePixelRatio);
    const host = document.createElement('div');
    document.body.appendChild(host);

    const read = (outer, inner) => {
        const w = document.createElement('div');
        w.innerHTML = '<div style="' + outer + '"><div data-m style="' + inner + '">x</div></div>';
        host.appendChild(w);
        const el = w.querySelector('[data-m]');
        const cs = getComputedStyle(el);
        const got = {
            width: cs.width,
            height: cs.height,
            paddingLeft: cs.paddingLeft,
            rect: String(el.getBoundingClientRect().width),
        };
        w.remove();
        return got;
    };
    const put = (name, outer, inner) => {
        const r = read(outer, inner);
        for (const k of Object.keys(r)) out[name + '.' + k] = r[k];
    };

    // The parent plan's own cases.
    put('pct33_3', 'width:400px', 'width:33.3%');
    put('px133_2', 'width:400px', 'width:133.2px');
    put('px133_333', 'width:400px', 'width:133.333px');
    put('h33_3', 'width:400px', 'height:33.3px');
    put('px100_0078125', 'width:400px', 'width:100.0078125px');
    put('pct7', 'width:400px', 'width:7%');
    put('pad33_3', 'width:400px', 'padding-left:33.3%');
    // Two lengths chosen so a 1/64 floor and a 1/128 floor differ: the fraction
    // sits between two 1/128 steps in one case and lands on a 1/128 step that
    // is not a 1/64 step in the other.
    put('px100_012', 'width:400px', 'width:100.012px');
    put('px100_0117188', 'width:400px', 'width:100.0117188px');
    put('pct33_35', 'width:400px', 'width:33.35%');

    host.remove();
    return out;
})();
