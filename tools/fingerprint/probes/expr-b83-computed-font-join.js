// What `getComputedStyle(el).font` is rebuilt from, and in which spellings.
//
// The computed join is NOT the specified one. `el.style.font` echoes the tokens
// that were stored, so `font: bold condensed 16px/1.4 serif` reads back with
// `bold` and `condensed` and `1.4`; the COMPUTED side resolves the weight to a
// number and the line height to px -- and then, measured, writes the stretch
// back as a KEYWORD even though computed `font-stretch` is a percentage.
//
// So the mapping goes both ways for one of the seven parts, which is exactly the
// sort of thing to read rather than derive. Each case sets longhands directly, so
// the join is exercised without the shorthand parser in the way, and the
// individual computed longhands are reported beside the joined text so a
// mismatch can be attributed.
(() => {
    const out = {};
    const parent = document.createElement('div');
    document.documentElement.appendChild(parent);
    const el = document.createElement('div');
    parent.appendChild(el);

    const read = (name, decl, parentDecl) => {
        parent.setAttribute('style', parentDecl || '');
        el.setAttribute('style', decl);
        const cs = getComputedStyle(el);
        out[name + '.font'] = String(cs.font);
        out[name + '.parts'] = ['font-style', 'font-variant-caps', 'font-weight', 'font-stretch', 'font-size', 'line-height', 'font-family']
            .map((p) => cs.getPropertyValue(p)).join(' ~ ');
    };

    read('bare', '');
    read('sizeFamily', 'font-size:13px;font-family:serif');
    read('weightKeyword', 'font-size:16px;font-family:serif;font-weight:bold');
    read('weightNumber', 'font-size:16px;font-family:serif;font-weight:350');
    read('weight400', 'font-size:16px;font-family:serif;font-weight:400');
    read('styleItalic', 'font-size:16px;font-family:serif;font-style:italic');
    read('obliqueAngle', 'font-size:16px;font-family:serif;font-style:oblique 20deg');
    read('smallCaps', 'font-size:16px;font-family:serif;font-variant-caps:small-caps');
    // Every stretch keyword, and percentages -- both ones that have a keyword
    // and ones that do not.
    for (const s of ['normal', 'condensed', 'ultra-expanded', '100%', '75%', '87.5%', '60%', '133%']) {
        read('stretch ' + s, 'font-size:16px;font-family:serif;font-stretch:' + s);
    }
    // Line height in each shape.
    for (const lh of ['normal', '1.4', '24px', '150%', '2em']) {
        read('line ' + lh, 'font-size:16px;font-family:serif;line-height:' + lh);
    }
    // A variant the `font` shorthand cannot express: does the computed join
    // answer anything at all?
    read('allSmallCaps', 'font-size:16px;font-family:serif;font-variant-caps:all-small-caps');
    read('kerningNone', 'font-size:16px;font-family:serif;font-kerning:none');
    read('sizeAdjust', 'font-size:16px;font-family:serif;font-size-adjust:0.5');
    // And the shorthand, for the round trip.
    read('shorthandAll', 'font:italic small-caps bold condensed 16px/1.4 serif');
    read('shorthandMin', 'font:13px serif');
    // Inherited rather than declared.
    read('inherited', '', 'font:italic 700 20px/2 monospace');

    el.remove();
    parent.remove();
    return out;
})();
