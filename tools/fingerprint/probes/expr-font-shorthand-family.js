// Does the quoting of a spaced family name follow the family into the `font`
// shorthand, and what happens to an escaped space in a bare identifier?
//
// Companion to expr-computed-font-family.js: that one showed Chrome quoting
// `Adwaita Sans` and this engine leaving it bare. Before touching the
// serialiser, this pins the two shapes the change could overreach into -- the
// shorthand, whose leading tokens are keywords that must stay bare, and an
// identifier that carries its space as an escape.
(() => {
    const out = {};
    const d = document.createElement('div');
    document.body.appendChild(d);

    const shorthand = [
        '12px Adwaita Sans',
        'italic bold 12px/1.5 Adwaita Sans, serif',
        '12px serif',
        'small-caps 400 16px Times New Roman',
    ];
    for (const c of shorthand) {
        d.style.font = '';
        d.style.font = c;
        out['font: ' + c] = {
            inline: d.style.font,
            family: d.style.fontFamily,
            computedFamily: getComputedStyle(d).fontFamily,
        };
    }

    const escaped = ['My\\ Font', 'A\\,B', '\\41 dwaita Sans', 'a  b', 'Initial Value'];
    for (const c of escaped) {
        d.style.font = '';
        d.style.fontFamily = '';
        d.style.fontFamily = c;
        out['font-family: ' + c] = {
            inline: d.style.fontFamily,
            computedFamily: getComputedStyle(d).fontFamily,
        };
    }

    d.remove();
    return out;
})()
