// What a declared `transform-origin` / `perspective-origin` computes to.
//
// The claim: a declared percentage resolves against the BORDER box, and this
// engine throws the declaration away and always reports the box centre. Before
// building on it: which box (border vs content vs padding), what keywords and
// lengths do, what the three-value form with a z axis does, and what happens
// when there is no box at all -- `display: none` must keep reporting the
// specified value, which css/computed_unrendered_percentages.html already
// asserts and a fix here must not undo.
(() => {
    const out = {};
    const host = document.createElement('div');
    document.body.appendChild(host);

    // A box whose border, padding and content boxes are all different sizes, so
    // a wrong choice among them is visible rather than a coincidence.
    // content 200x10, padding 220x14, border 240x24.
    const BOX = 'width:200px;height:10px;padding:0 10px;border:10px solid;border-top-width:7px;border-bottom-width:7px;box-sizing:content-box';

    const probe = (decl, prop, extra) => {
        const el = document.createElement('div');
        el.style.cssText = BOX + ';' + (extra || '') + ';' + decl;
        host.appendChild(el);
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        const got = cs.getPropertyValue(prop);
        el.remove();
        return { got, box: Math.round(r.width) + 'x' + Math.round(r.height) };
    };

    const CASES = [
        ['transform-origin', 'transform-origin:25% 75%'],
        ['transform-origin', 'transform-origin:0% 0%'],
        ['transform-origin', 'transform-origin:100% 100%'],
        ['transform-origin', 'transform-origin:10px 20px'],
        ['transform-origin', 'transform-origin:left top'],
        ['transform-origin', 'transform-origin:right bottom'],
        ['transform-origin', 'transform-origin:center'],
        ['transform-origin', 'transform-origin:left'],
        ['transform-origin', 'transform-origin:top'],
        ['transform-origin', 'transform-origin:25%'],
        ['transform-origin', 'transform-origin:left top 10px'],
        ['transform-origin', 'transform-origin:50% 50% 30px'],
        ['transform-origin', 'transform-origin:1em 2em'],
        // No declaration at all: the default is the box centre.
        ['transform-origin', 'color:red'],
        ['perspective-origin', 'perspective-origin:25% 75%'],
        ['perspective-origin', 'perspective-origin:left top'],
        ['perspective-origin', 'perspective-origin:10px 20px'],
        ['perspective-origin', 'color:red'],
    ];
    for (const [prop, decl] of CASES) {
        const r = probe(decl, prop);
        out[decl + ' -> ' + prop] = r.got + '   (box ' + r.box + ')';
    }

    // The control that must not change: with no box, the specified value is
    // reported rather than resolved.
    for (const extra of ['display:none', 'visibility:hidden']) {
        out['transform-origin:25% 75% + ' + extra] =
            probe('transform-origin:25% 75%', 'transform-origin', extra).got;
    }
    // And a detached element, which is empty now.
    const loose = document.createElement('div');
    loose.style.cssText = BOX + ';transform-origin:25% 75%';
    out['transform-origin:25% 75% detached'] =
        JSON.stringify(getComputedStyle(loose).getPropertyValue('transform-origin'));

    host.remove();
    return JSON.stringify(out, null, 1);
})()
