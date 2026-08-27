// Every case `tests/element/layout_unit_grid.html` asserts, read again at a
// device scale factor of 2.
//
// That test encodes the parent plan's model: a used length floors onto a 1/64px
// grid. The grid turned out to be 1/64 of a DEVICE pixel, and this engine claims
// devicePixelRatio 2, so each of those assertions is a 1x answer. Reading the
// same markup the test builds -- rather than a paraphrase of it -- is what makes
// the rewrite a transcription instead of a second guess.
//
// Run twice, `--chrome-arg --force-device-scale-factor=1` and `=2`: the first
// column has to reproduce the assertions in the file today, which is what says
// the markup here matches the markup there.
(() => {
    const out = { dpr: String(window.devicePixelRatio) };
    const host = document.createElement('div');
    document.body.appendChild(host);

    const read = (outer, inner, prop) => {
        const w = document.createElement('div');
        w.innerHTML = '<div style="' + outer + '"><div data-m style="' + inner + '">x</div></div>';
        host.appendChild(w);
        const el = w.querySelector('[data-m]');
        const v = prop === 'rect' ? String(el.getBoundingClientRect().width) : String(getComputedStyle(el)[prop]);
        w.remove();
        return v;
    };

    const cases = [
        ['width 33.3%', 'width:400px', 'width:33.3%', 'width'],
        ['width 33.3% rect', 'width:400px', 'width:33.3%', 'rect'],
        ['width 133.2px', 'width:400px', 'width:133.2px', 'width'],
        ['width 133.333px', 'width:400px', 'width:133.333px', 'width'],
        ['height 33.3px', 'width:400px', 'height:33.3px', 'height'],
        ['width 100.0078125px', 'width:400px', 'width:100.0078125px', 'width'],
        ['width 100.001px', 'width:400px', 'width:100.001px', 'width'],
        ['width 7%', 'width:400px', 'width:7%', 'width'],
        ['width 10% of 1904', '', 'width:10%', 'width'],
        ['padding 33.3%', 'width:400px', 'padding-left:33.3%', 'paddingLeft'],
        ['padding 33.3% width', 'width:400px', 'padding-left:33.3%', 'width'],
        ['padding 10.1px', 'width:400px', 'padding-left:10.1px', 'paddingLeft'],
        ['margin 10.1px', 'width:400px', 'margin-left:10.1px', 'marginLeft'],
        ['font-size 13.3px', 'width:400px', 'font-size:13.3px', 'fontSize'],
        ['padding 0.5em', 'width:400px', 'font-size:13.3px;padding-left:0.5em', 'paddingLeft'],
        ['letter-spacing', 'width:400px', 'letter-spacing:0.7px', 'letterSpacing'],
        ['origin of 33.3%', 'width:400px', 'width:33.3%', 'transformOrigin'],
    ];
    for (const [name, outer, inner, prop] of cases) out[name] = read(outer, inner, prop);

    host.remove();
    return out;
})();
