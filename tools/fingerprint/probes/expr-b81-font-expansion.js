// What Chrome stores when the `font` shorthand is set.
//
// `font` is `.unmodelled` in chrome_shorthands.zig -- "its grammar is the thing
// no model reproduced" -- so this engine keeps the declaration whole and the
// nineteen longhands are never set. The cost was measured in
// expr-b81-font-shorthand-layout.js: `font:13px serif` leaves computed
// font-size at 16px and the box at the default font's width, for every size.
//
// Chrome keeps no shorthand in a declaration, so `style.length` and the indexed
// names ARE its expansion, read directly rather than derived from the grammar.
// Each case reports the entry count, every name in index order, and the value
// stored against it -- which is what a `font` expander has to reproduce.
(() => {
    const out = {};
    const el = document.createElement('div');
    document.documentElement.appendChild(el);

    const cases = {
        // The two-part minimum: size and family.
        min: '13px serif',
        // Sizes and families of every shape the grammar allows.
        familyList: '13px "Helvetica Neue", Arial, sans-serif',
        sizePercent: '120% serif',
        sizeKeyword: 'medium serif',
        sizeEm: '1.5em serif',
        // Optional leading style / variant / weight / stretch, in and out of
        // order, since the grammar is a `||` group.
        bold: 'bold 16px serif',
        italicBold: 'italic bold 16px serif',
        boldItalic: 'bold italic 16px serif',
        smallCaps: 'small-caps 16px serif',
        weight700: '700 16px serif',
        stretch: 'condensed 16px serif',
        all: 'italic small-caps bold condensed 16px/1.4 serif',
        // Line height, in each unit the grammar allows.
        lineNumber: '16px/1.4 serif',
        linePx: '16px/24px serif',
        linePercent: '16px/150% serif',
        lineNormal: '16px/normal serif',
        // A system keyword, which this engine already expands, as a control.
        caption: 'caption',
        // Values Chrome REFUSES, so the expander refuses the same ones: no
        // family, a bad weight, `font-variant` beyond small-caps.
        noFamily: '13px',
        badWeight: '1001 16px serif',
        inheritPart: 'bold inherit serif',
        wideKeyword: 'inherit',
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
        out[name + '.entries'] = entries.join(' | ');
        out[name + '.readback'] = el.style.font;
        out[name + '.cssText'] = el.style.cssText;
        // And what the cascade then computes, which is what the layout reads.
        const cs = getComputedStyle(el);
        out[name + '.computed'] = ['font-style', 'font-variant-caps', 'font-weight', 'font-stretch', 'font-size', 'line-height', 'font-family']
            .map((p) => p + '=' + cs.getPropertyValue(p)).join(' | ');
        out[name + '.computedFont'] = cs.font;
    }

    el.remove();
    return out;
})();
