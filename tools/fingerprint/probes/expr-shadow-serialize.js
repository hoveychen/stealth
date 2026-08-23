// How does Chrome write a `box-shadow` / `text-shadow` back out? The Cloudflare
// @keyframes payload has seven rules whose shadow reads back reordered: the
// oracle says `rgb(34, 139, 73) 0px 0px 0px inset` where we say
// `inset 0 0 0 rgb(34, 139, 73)`. Three things move -- colour to the front,
// bare `0` to `0px`, `inset` to the end -- so pin each one separately, and pin
// what Chrome does NOT do (it does not fill in a blur/spread the author left
// out).
(() => {
    const sheet = new CSSStyleSheet();
    const probe = (decl) => {
        let text = null;
        let err = null;
        try {
            sheet.replaceSync('x{' + decl + '}');
            const rule = sheet.cssRules[0];
            text = rule.style.cssText;
        } catch (e) {
            err = String((e && e.name) || e);
        }
        return { in: decl, cssText: text, err };
    };
    return JSON.stringify([
        // component order: where does the colour go?
        probe('box-shadow:red 1px 2px'),
        probe('box-shadow:1px 2px red'),
        probe('box-shadow:1px 2px'),
        probe('box-shadow:1px 2px 3px red'),
        probe('box-shadow:1px 2px 3px 4px red'),
        probe('box-shadow:red 1px 2px 3px 4px'),
        // does Chrome pad out the omitted blur/spread?
        probe('box-shadow:1px 1px red,2px 2px blue'),
        probe('box-shadow:0 0 0 red'),
        probe('box-shadow:0 0 red'),
        // inset placement
        probe('box-shadow:inset 1px 2px red'),
        probe('box-shadow:1px 2px red inset'),
        probe('box-shadow:red inset 1px 2px'),
        probe('box-shadow:INSET 1px 2px RED'),
        // the exact oracle shape
        probe('box-shadow:inset 0 0 0 rgb(34, 139, 73)'),
        probe('box-shadow:inset 0 0 0 #228b49'),
        // zero-length spelling in each slot
        probe('box-shadow:0 0 0 0 red'),
        probe('box-shadow:0px 0em 0 0 red'),
        // negative + decimal lengths
        probe('box-shadow:-1px -2px 0.5px red'),
        probe('box-shadow:1.0px 2.50px red'),
        // multiple layers, mixed shapes
        probe('box-shadow:inset 0 0 0 red,0 1px 2px blue'),
        probe('box-shadow:0 1px 2px rgba(0,0,0,.5),inset 0 0 0 1px green'),
        // no colour at all -- does Chrome invent currentcolor?
        probe('box-shadow:inset 1px 2px 3px 4px'),
        // a colour written as a hex or an rgba(), folded on the way
        probe('box-shadow:1px 2px #228b49'),
        probe('box-shadow:0 1px 2px rgba(0,0,0,.5)'),
        // values carrying no layer to order
        probe('box-shadow:none'),
        probe('box-shadow:inherit'),
        probe('box-shadow:var(--s)'),
        // text-shadow: same family, no inset and no spread
        probe('text-shadow:red 1px 2px'),
        probe('text-shadow:1px 2px red'),
        probe('text-shadow:1px 2px 3px red'),
        probe('text-shadow:0 0 red'),
        probe('text-shadow:1px 1px red,2px 2px blue'),
        probe('text-shadow:none'),
        // -webkit-box-shadow alias
        probe('-webkit-box-shadow:1px 2px red'),
        // does the longhand read back the same as inside a rule?
        probe('box-shadow:1px 2px red;color:blue'),
    ], null, 0);
})()
