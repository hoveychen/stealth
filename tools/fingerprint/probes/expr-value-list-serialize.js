// How does Chrome write a comma-separated or slash-separated property value
// back out? The challenge page's `@keyframes` payload still differs from the
// oracle on `font-family`, `stroke-dasharray` and `grid-area`, all of which we
// join the way the author wrote them rather than the way Blink re-serialises.
(() => {
    const probe = (decl) => {
        const sheet = new CSSStyleSheet();
        let cssText = null;
        let err = null;
        try {
            sheet.replaceSync('x{' + decl + '}');
            cssText = sheet.cssRules[0].style.cssText;
        } catch (e) {
            err = String(e && e.name || e);
        }
        return { in: decl, out: cssText, err };
    };
    return JSON.stringify([
        // comma lists written tight
        probe('font-family:a,b,c'),
        probe('font-family:-apple-system,system-ui,"Segoe UI",arial,sans-serif'),
        probe('font-family: a ,  b'),
        probe('stroke-dasharray:32 32'),
        probe('stroke-dasharray:0,100,0'),
        probe('stroke-dasharray: 0 100 0'),
        probe('stroke-dasharray:166'),
        // slash-separated
        probe('grid-area:1/1'),
        probe('grid-area:1 / 2 / 3 / 4'),
        probe('grid-row:1/3'),
        probe('font:12px/1.5 arial'),
        probe('border-radius:1px 2px/3px 4px'),
        probe('background:url(a) 0 0/cover no-repeat'),
        // other comma-list properties, to see whether the rule is general
        probe('transition:color 1s,background 2s'),
        probe('will-change:opacity,transform'),
        probe('voice-family:a,b'),
        probe('grid-template-columns:1fr 1fr'),
        probe('background-image:url(a),url(b)'),
        probe('box-shadow:1px 1px red,2px 2px blue'),
        probe('mask:none,none'),
        probe('src:local(a),local(b)'),
        // a custom property is verbatim, which is the control
        probe('--x:a,b,c'),
    ], null, 0);
})()
