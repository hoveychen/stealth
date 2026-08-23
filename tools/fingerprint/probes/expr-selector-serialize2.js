// Follow-ups to expr-selector-serialize.js: does the `selectorText` setter
// re-serialise the way the parser does, and how are attribute values quoted
// when the value itself needs escaping?
(() => {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync('x{color:red}');
    const rule = sheet.cssRules[0];
    const setThenRead = (selector) => {
        try {
            rule.selectorText = selector;
            return { in: selector, out: rule.selectorText };
        } catch (e) {
            return { in: selector, err: String(e && e.name || e) };
        }
    };
    const parseThenRead = (selector) => {
        const s = new CSSStyleSheet();
        try {
            s.replaceSync(selector + '{color:red}');
            return { in: selector, out: s.cssRules[0].selectorText };
        } catch (e) {
            return { in: selector, err: String(e && e.name || e) };
        }
    };
    return JSON.stringify({
        setter: [
            setThenRead('a,b'),
            setThenRead('a~b'),
            setThenRead('A:HOVER'),
            setThenRead('a:before'),
            setThenRead('!!!bad'),
        ],
        quoting: [
            parseThenRead('[a="b\'c"]'),
            parseThenRead('[a="b\\"c"]'),
            parseThenRead('[a="b\\\\c"]'),
            parseThenRead('[a=""]'),
            parseThenRead('[a="b c" i]'),
            parseThenRead('[a="b" I]'),
            parseThenRead('[a="b" s]'),
            parseThenRead('[a|=b]'),
            parseThenRead('[ a = b ]'),
        ],
        misc: [
            parseThenRead('a::FIRST-LINE'),
            parseThenRead('a:first-letter'),
            parseThenRead('a::selection'),
            parseThenRead('LI:NTH-CHILD(2N+1)'),
            parseThenRead('a:NOT(B,C)'),
            parseThenRead('a\\.b'),
            parseThenRead('#a\\ b'),
            parseThenRead('svg|circle'),
            parseThenRead('a >b'),
            parseThenRead('a\t\n>\t\nb'),
            parseThenRead('a:has(>b,+c)'),
            parseThenRead(':nth-child(2 of a,b)'),
        ],
    }, null, 0);
})()
