// What a CSS-wide keyword stored against a longhand computes to.
//
// Expanding `font: inherit` into nineteen `inherit`s is what Chrome stores, and
// it is only an improvement if the computed path then resolves them. If it
// answers the literal `inherit`, expanding has traded a set of computed values
// that happened to be right for a set no browser ever answers -- and the
// under-expansion rule in shorthand.zig says keep the declaration whole instead.
//
// `margin` already takes that path (`expand`'s CSS-wide branch sets all four
// longhands to the keyword), so the question is whether the gap is general and
// predates `font` or whether adding `font` to it would be new. Both are read
// here, on an element whose parent sets a value worth inheriting.
(() => {
    const out = {};
    const parent = document.createElement('div');
    parent.setAttribute('style', 'margin-left:40px;padding-left:30px;font:italic 700 20px/2 monospace');
    document.documentElement.appendChild(parent);
    const el = document.createElement('div');
    parent.appendChild(el);

    const read = (name, decl, props) => {
        el.setAttribute('style', decl);
        const cs = getComputedStyle(el);
        out[name + '.count'] = String(el.style.length);
        out[name + '.computed'] = props.map((p) => p + '=' + cs.getPropertyValue(p)).join(' | ');
        out[name + '.stored'] = props.map((p) => p + '=' + el.style.getPropertyValue(p)).join(' | ');
    };

    const fontProps = ['font-style', 'font-weight', 'font-size', 'line-height', 'font-family'];
    read('marginInherit', 'margin: inherit', ['margin-left', 'margin-top']);
    read('marginInitial', 'margin: initial', ['margin-left']);
    read('marginUnset', 'margin: unset', ['margin-left']);
    read('paddingInherit', 'padding: inherit', ['padding-left']);
    read('fontInherit', 'font: inherit', fontProps);
    read('fontInitial', 'font: initial', fontProps);
    read('fontUnset', 'font: unset', fontProps);
    read('fontSizeInherit', 'font-size: inherit', ['font-size']);
    read('nothing', '', fontProps);

    el.remove();
    parent.remove();
    return out;
})();
