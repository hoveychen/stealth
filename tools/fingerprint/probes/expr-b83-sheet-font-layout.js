// Does a stylesheet RULE reach the layout's font, or only an inline style?
//
// The `font` shorthand now expands on both paths, so a rule `.x{font:13px serif}`
// computes font-size 13px. The box did not follow, which points past the
// shorthand at how the layout resolves its font at all. This separates the two:
// the same 13px is delivered as a rule and as an inline style, once through the
// shorthand and once through the longhand, and the computed value is read beside
// the box so "the cascade knows" and "the layout knows" can be told apart.
(() => {
    const out = {};
    const sheet = document.createElement('style');
    sheet.textContent = '.b83sh{font:13px serif} .b83lh{font-size:13px;font-family:serif}';
    document.documentElement.appendChild(sheet);
    const make = (cls, style) => {
        const el = document.createElement('div');
        el.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;' + (style || ''));
        if (cls) el.className = cls;
        el.textContent = 'aaa bbb ccc';
        document.documentElement.appendChild(el);
        return el;
    };
    const read = (name, el) => {
        out[name + '.rect'] = String(el.getBoundingClientRect().width);
        out[name + '.computedSize'] = String(getComputedStyle(el).fontSize);
        el.remove();
    };
    read('ruleShorthand', make('b83sh', ''));
    read('ruleLonghand', make('b83lh', ''));
    read('inlineShorthand', make('', 'font:13px serif'));
    read('inlineLonghand', make('', 'font-size:13px;font-family:serif'));
    sheet.remove();
    return out;
})();
