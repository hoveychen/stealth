// The indexed property list of a computed style declaration, which is what the
// widget serialises into a 30918-byte dictionary (30902 here -- sixteen bytes
// short, so a name or two is missing or differently spelled).
(() => {
    const cs = getComputedStyle(document.documentElement);
    const names = [];
    for (let i = 0; i < cs.length; i++) names.push(cs[i]);
    return { length: cs.length, json: JSON.stringify(Object.assign({}, names)).length, names };
})();
