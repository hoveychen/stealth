// How a family name is stored and read back, asked of the LONGHAND.
//
// Chrome's `font` shorthand serialises a multi-identifier family as a quoted
// string: `font: 16px Times New Roman` reads back `16px "Times New Roman"`, and
// `font: 16px bold serif` reads back `16px "bold serif"`. Before an expander
// starts quoting things, the question is whose rule that is -- the shorthand's
// or `font-family`'s -- because if the longhand already answers unquoted here
// then the gap is `font-family`'s serialisation and predates any of this.
(() => {
    const out = {};
    const el = document.createElement('div');
    document.documentElement.appendChild(el);
    const cases = [
        'Times New Roman',
        '"Times New Roman"',
        'serif',
        'Arial, sans-serif',
        'Times New Roman, serif',
        'bold serif',
    ];
    for (const v of cases) {
        el.setAttribute('style', '');
        el.style.fontFamily = v;
        out['set ' + v] = 'style=' + el.style.fontFamily + ' | computed=' + getComputedStyle(el).fontFamily;
    }
    el.remove();
    return out;
})();
