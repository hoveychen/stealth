// What does a style rule's `selectorText` read back as? Chrome does not hand
// back the author's bytes: it re-serialises the parsed selector list, which is
// why a minified sheet's `a,b` comes back as `a, b` and `x~y` as `x ~ y`. The
// Cloudflare @keyframes payload is 329 characters longer on Chrome than here
// almost entirely because of that re-serialisation, so pin the exact rules.
(() => {
    const sheet = new CSSStyleSheet();
    const probe = (selector) => {
        let text = null;
        let css = null;
        let err = null;
        try {
            sheet.replaceSync(selector + '{color:red}');
            const rule = sheet.cssRules[0];
            text = rule.selectorText;
            css = rule.cssText;
        } catch (e) {
            err = String(e && e.name || e);
        }
        return { in: selector, selectorText: text, cssText: css, err };
    };
    return JSON.stringify([
        // list separator
        probe('a,b'),
        probe('a ,  b'),
        probe('a,b,c'),
        probe('#x,.y,z'),
        // combinators
        probe('a~b'),
        probe('a>b'),
        probe('a+b'),
        probe('a   b'),
        probe('a >   b'),
        probe('a||b'),
        // combinator-looking bytes that must not be spaced
        probe('[class~="x"]'),
        probe('[class|="x"]'),
        probe('[class^="x"]'),
        probe('a[href~="b,c"]'),
        // commas that are not list separators
        probe(':not(a,b)'),
        probe(':is(a,b)'),
        probe(':where(a , b)'),
        probe('a:nth-child(2n+1)'),
        probe(':not(a~b)'),
        // case handling
        probe('DIV'),
        probe('DIV.Foo#Bar'),
        probe('A:HOVER'),
        probe('[HREF]'),
        probe('[href=X]'),
        // pseudo-element spelling
        probe('a:before'),
        probe('a::before'),
        probe('a::BEFORE'),
        // quoting / escapes
        probe("[a='b']"),
        probe('[a=b]'),
        probe('.\\31 23'),
        probe('a[b="c d"]'),
        // whitespace and newlines in the prelude
        probe('a,\n  b'),
        probe('  a  ,  b  '),
        // universal
        probe('*'),
        probe('* > *'),
        probe('*|a'),
        // nesting-ish
        probe('a:has(> b)'),
        probe('a:has(+b)'),
    ], null, 0);
})()
