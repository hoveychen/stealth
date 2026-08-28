// Which enumeration produces the widget's 30918-byte index-to-name dictionary?
// This engine's is 30902, so a sixteen-byte hunt needs the right list first.
(() => {
    const el = document.createElement('div');
    const out = {};
    const j = (arr) => JSON.stringify(Object.assign({}, arr)).length;
    const forIn = (o) => { const a = []; for (const k in o) a.push(k); return a; };
    const cs = getComputedStyle(document.documentElement);
    const idx = (o) => { const a = []; for (let i = 0; i < o.length; i++) a.push(o[i]); return a; };

    out['computed indexed'] = j(idx(cs));
    out['inline for-in'] = j(forIn(el.style));
    out['computed for-in'] = j(forIn(cs));
    out['gopn(CSSStyleDeclaration.prototype)'] = j(Object.getOwnPropertyNames(CSSStyleDeclaration.prototype));
    out['keys(el.style)'] = j(Object.keys(el.style));
    out['forIn sorted'] = j(forIn(el.style).slice().sort());
    out['counts'] = {
        computedIndexed: cs.length,
        inlineForIn: forIn(el.style).length,
        computedForIn: forIn(cs).length,
        gopnProto: Object.getOwnPropertyNames(CSSStyleDeclaration.prototype).length,
    };
    out['inline for-in first 6'] = forIn(el.style).slice(0, 6);
    return out;
})();
