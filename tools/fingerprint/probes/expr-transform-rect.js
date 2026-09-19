// What a CSS transform does to the boxes a script can read: the rect, the
// client rects, offsetLeft/offsetTop/offsetWidth, and the computed transform.
// iphey builds exactly this (100x100 at left:-9999px, rotate(45deg), plus a
// .shift class adding scale(1.123456789)) and sends all three readings.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute; inset:0; pointer-events:none;');
    const el = document.createElement('div');
    el.setAttribute('style', 'position:absolute; top:0; left:-9999px; width:100px; height:100px; visibility:hidden;');
    host.appendChild(el);
    document.body.appendChild(host);

    const round = (n) => (typeof n === 'number' ? Math.round(n * 1000) / 1000 : n);
    const read = (label) => {
        const r = el.getBoundingClientRect();
        const list = el.getClientRects();
        out[label] = {
            rect: [round(r.x), round(r.y), round(r.width), round(r.height)],
            rects: list.length,
            rect0: list.length ? [round(list[0].x), round(list[0].y), round(list[0].width), round(list[0].height)] : null,
            offset: [el.offsetLeft, el.offsetTop, el.offsetWidth, el.offsetHeight],
            client: [el.clientWidth, el.clientHeight],
            computed: getComputedStyle(el).transform,
        };
    };

    const cases = {
        none: '',
        rotate45: 'rotate(45deg)',
        rotate45scale: 'rotate(45deg) scale(1.123456789)',
        scale2: 'scale(2)',
        scaleXY: 'scale(2, 0.5)',
        translatePct: 'translate(50%, 10%)',
        translatePx: 'translateX(-12.5px)',
        skewX: 'skewX(30deg)',
        matrix: 'matrix(1, 0.5, -0.5, 1, 10, 20)',
        originTopLeft: 'rotate(45deg)',
        rotateThenTranslate: 'rotate(90deg) translateX(10px)',
        translateThenRotate: 'translateX(10px) rotate(90deg)',
    };
    for (const [label, value] of Object.entries(cases)) {
        el.style.transformOrigin = label === 'originTopLeft' ? '0 0' : '';
        el.style.transform = value;
        read(label);
    }
    el.style.transformOrigin = '';
    el.style.transform = '';

    // An ancestor's transform moves the descendant too, and composes with the
    // descendant's own.
    host.style.transform = 'translateX(30px) scale(2)';
    el.style.transform = 'rotate(45deg)';
    read('ancestorAndSelf');
    host.style.transform = '';
    el.style.transform = '';

    host.remove();
    return out;
})()
