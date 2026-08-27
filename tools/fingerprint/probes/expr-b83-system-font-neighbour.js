// The non-system `font` case `css/computed_system_fonts.html` asserts, read off
// Chrome.
//
// That test pins what a `font` value which is NOT one of the six system
// keywords does, and its comment says outright that the answer it asserts is the
// engine's own gap rather than Chrome's: "`font`'s grammar is unmodelled, so
// such a value is still kept whole and the longhands keep their initial values
// -- 16px Times, not 20px Georgia. That is pre-existing and is not what this
// plan fixes". `font-shorthand-cascade` is what fixes it, so the assertion has
// to become Chrome's answer -- read here rather than copied out of the engine.
//
// The system-keyword rows are read alongside, so the same probe says whether
// making `font` joinable moved them.
(() => {
    const out = {};
    const el = document.createElement('div');
    document.documentElement.appendChild(el);

    const read = (name, decl) => {
        el.setAttribute('style', decl);
        const cs = getComputedStyle(el);
        out[name + '.fontFamily'] = String(cs.fontFamily);
        out[name + '.fontSize'] = String(cs.fontSize);
        out[name + '.fontStyle'] = String(cs.fontStyle);
        out[name + '.fontWeight'] = String(cs.fontWeight);
        out[name + '.lineHeight'] = String(cs.lineHeight);
        out[name + '.font'] = String(cs.font);
        out[name + '.styleFont'] = String(el.style.font);
        out[name + '.length'] = String(el.style.length);
    };

    read('caption', 'font: caption !important');
    read('georgia', 'font: italic 700 20px/1.5 Georgia');
    read('familyKeywordName', 'font-family: caption');

    el.remove();
    return out;
})();
