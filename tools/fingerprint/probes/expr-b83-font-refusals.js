// Which `font` values Chrome throws the whole declaration away for.
//
// expr-b81-font-expansion.js measured three refusals -- `13px` with no family,
// `1001 16px serif` with a weight out of range, and `bold inherit serif` with a
// CSS-wide keyword as a part -- each leaving style.length at 0. An expander has
// to know the rest of the boundary, because refusing something Chrome accepts
// loses a page a style it was written with, and accepting something Chrome
// refuses stores values no browser ever had.
//
// So the shapes are read rather than reasoned about: a missing size, a missing
// both, a doubled part, a part after the size, an unknown leading identifier,
// the two-token `oblique <angle>` style, and the weight range's own edges.
//
// `count` of 0 means Chrome dropped the declaration. Anything else is the
// expansion it stored, and `entries` says what into.
(() => {
    const out = {};
    const el = document.createElement('div');
    document.documentElement.appendChild(el);

    const cases = {
        // The mandatory tail, each half missing.
        noFamily: '13px',
        noSize: 'serif',
        noSizeWithParts: 'bold serif',
        neither: 'bold',
        lineHeightNoFamily: '16px/1.4',
        // A part repeated, and two parts of the same kind.
        doubledWeight: 'bold bold 16px serif',
        twoStyles: 'italic oblique 16px serif',
        doubledNormal: 'normal normal 16px serif',
        fourNormals: 'normal normal normal normal 16px serif',
        // A leading identifier that is not a part of the grammar.
        unknownLeader: 'wibble 16px serif',
        // A part AFTER the size, which the grammar does not allow.
        weightAfterSize: '16px bold serif',
        // `oblique <angle>`, two tokens for one part.
        obliqueAngle: 'oblique 20deg 16px serif',
        obliqueBare: 'oblique 16px serif',
        // The weight range's edges, either side.
        weight1: '1 16px serif',
        weight1000: '1000 16px serif',
        weight1001: '1001 16px serif',
        weight0: '0 16px serif',
        weightFraction: '350.5 16px serif',
        weightNegative: '-1 16px serif',
        // A size the grammar takes and one it does not.
        sizeZero: '0 serif',
        sizeNegative: '-5px serif',
        sizeKeywordRelative: 'larger serif',
        // Multi-identifier family names, which are legal unquoted.
        familyTwoWords: '16px Times New Roman',
        familyQuoted: '16px "Times New Roman"',
        // A slash with nothing after it.
        danglingSlash: '16px/ serif',
        slashNoSize: '/1.4 serif',
        // Something this engine cannot judge, which should stay whole rather
        // than become a guess.
        withVar: '16px var(--f)',
        withCalc: 'calc(1px + 1em) serif',
        withComment: '16px /* c */ serif',
    };

    for (const [name, value] of Object.entries(cases)) {
        el.setAttribute('style', '');
        el.style.font = value;
        const entries = [];
        for (let i = 0; i < el.style.length; i++) {
            const prop = el.style[i];
            entries.push(prop + '=' + el.style.getPropertyValue(prop));
        }
        out[name + '.count'] = String(el.style.length);
        out[name + '.readback'] = el.style.font;
        // Only the seven the grammar names, so the line stays readable; the
        // twelve it never names were shown to be their initials already.
        out[name + '.named'] = ['font-style', 'font-variant-caps', 'font-weight', 'font-stretch', 'font-size', 'line-height', 'font-family']
            .map((p) => p + '=' + el.style.getPropertyValue(p)).join(' | ');
        void entries;
    }

    el.remove();
    return out;
})();
