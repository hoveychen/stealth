// What a `font-weight` and a `font-stretch` keyword COMPUTE to.
//
// Found while checking the font shorthand's expansion against Chrome: with
// `font: 13px serif` stored, Chrome's computed font-weight is `400` and its
// computed font-stretch is `100%`, where this engine echoes the stored keyword
// `normal` for both. The specified value is the keyword in both engines -- it is
// only the computed one that resolves -- so this is a computed-value mapping and
// not a parsing difference.
//
// Both keyword families are swept, plus the two relative weights, which are not
// a table at all: `bolder` and `lighter` resolve against the INHERITED weight,
// so each is read under three different parents. `<b>` is read too, since the UA
// stylesheet sets its weight rather than the author.
(() => {
    const out = {};
    const parent = document.createElement('div');
    document.documentElement.appendChild(parent);
    const el = document.createElement('div');
    parent.appendChild(el);

    const read = (key, parentDecl, decl, prop) => {
        parent.setAttribute('style', parentDecl);
        el.setAttribute('style', decl);
        out[key] = 'specified=' + String(el.style.getPropertyValue(prop)) +
            ' | computed=' + String(getComputedStyle(el).getPropertyValue(prop));
    };

    for (const w of ['normal', 'bold', '100', '400', '700', '900', '1000', '350.5']) {
        read('weight ' + w, '', 'font-weight:' + w, 'font-weight');
    }
    // The two relative ones, against three inherited weights.
    for (const p of ['font-weight:normal', 'font-weight:700', 'font-weight:100']) {
        for (const w of ['bolder', 'lighter']) {
            read('rel ' + w + ' under ' + p, p, 'font-weight:' + w, 'font-weight');
        }
    }
    for (const s of ['normal', 'ultra-condensed', 'extra-condensed', 'condensed',
        'semi-condensed', 'semi-expanded', 'expanded', 'extra-expanded',
        'ultra-expanded', '50%', '87.5%', '200%']) {
        read('stretch ' + s, '', 'font-stretch:' + s, 'font-stretch');
    }
    // And through the shorthand, which is where this turned up.
    read('shorthand bold', '', 'font:bold 16px serif', 'font-weight');
    read('shorthand condensed', '', 'font:condensed 16px serif', 'font-stretch');
    read('shorthand plain weight', '', 'font:16px serif', 'font-weight');
    read('shorthand plain stretch', '', 'font:16px serif', 'font-stretch');

    el.remove();
    parent.remove();

    // The UA stylesheet's own bold, which no author declaration sets.
    const b = document.createElement('b');
    document.documentElement.appendChild(b);
    out['b element'] = 'computed=' + String(getComputedStyle(b).fontWeight);
    b.remove();
    return out;
})();
