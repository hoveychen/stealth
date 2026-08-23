// Two separate readings behind rules 115, 116 and 16 of the Cloudflare
// @keyframes payload.
//
// First: `transform: rotate(0deg) scale(1)` is thrown away by this engine and
// kept by Chrome. The measured arity table has `transform` down as taking one
// component, because the sweep that built it only ever offered identifier and
// generic-value pairs -- never two transform functions -- so a <transform-list>
// of more than one function reads as a declaration holding too much. Pin which
// multi-function values Chrome keeps and which it really does refuse.
//
// Second: `transform-origin: bottom center` reads back `center bottom`. Chrome
// writes the horizontal axis first and fills in the axis the author left out.
// `perspective-origin` takes the same rule.
(() => {
    const sheet = new CSSStyleSheet();
    const probe = (decl) => {
        let text = null;
        let err = null;
        try {
            sheet.replaceSync('x{' + decl + '}');
            text = sheet.cssRules[0].style.cssText;
        } catch (e) {
            err = String((e && e.name) || e);
        }
        return { in: decl, cssText: text, err };
    };
    return JSON.stringify([
        // --- a transform list of more than one function ---
        probe('transform:rotate(0deg) scale(1)'),
        probe('transform:rotate(45deg) scale(1)'),
        probe('transform:translate(1px, 2px) rotate(45deg) skewX(1deg)'),
        probe('transform:translateX(10px) rotate(1turn)'),
        probe('transform:rotate(45deg)'),
        probe('transform:none'),
        probe('-webkit-transform:rotate(45deg) scale(1)'),
        // a list Chrome really does refuse: a function next to a bare length
        probe('transform:rotate(45deg) 5px'),
        probe('transform:5px rotate(45deg)'),
        probe('transform:rotate(45deg) none'),
        // --- transform-origin, both axes ---
        probe('transform-origin:bottom center'),
        probe('transform-origin:center bottom'),
        probe('transform-origin:top left'),
        probe('transform-origin:left top'),
        probe('transform-origin:right bottom'),
        probe('transform-origin:bottom right'),
        // one keyword: the other axis is filled in
        probe('transform-origin:right'),
        probe('transform-origin:left'),
        probe('transform-origin:top'),
        probe('transform-origin:bottom'),
        probe('transform-origin:center'),
        // lengths and percentages are positions, not keywords
        probe('transform-origin:50% 50%'),
        probe('transform-origin:50%'),
        probe('transform-origin:10px'),
        probe('transform-origin:10px 20px'),
        // a keyword mixed with a length
        probe('transform-origin:left 20px'),
        probe('transform-origin:20px top'),
        probe('transform-origin:top 20px'),
        // a third value is the z offset
        probe('transform-origin:bottom right 10px'),
        probe('transform-origin:right bottom 10px'),
        probe('transform-origin:50% 50% 10px'),
        // case
        probe('transform-origin:BOTTOM CENTER'),
        // --- perspective-origin takes the same rule ---
        probe('perspective-origin:bottom right'),
        probe('perspective-origin:right'),
        probe('perspective-origin:center'),
        probe('perspective-origin:50% 50%'),
    ], null, 0);
})()
