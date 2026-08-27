// The whole `bolder` / `lighter` table, one row per inherited weight.
//
// Neither is a value: each resolves against the INHERITED computed weight, so a
// mapping needs all nine rows rather than the three that happened to be sampled
// first. Read off Chrome so the table in the engine is a transcription.
(() => {
    const out = {};
    const parent = document.createElement('div');
    document.documentElement.appendChild(parent);
    const el = document.createElement('div');
    parent.appendChild(el);
    for (const inherited of ['100', '200', '300', '400', '500', '600', '700', '800', '900', '1000', '350']) {
        parent.setAttribute('style', 'font-weight:' + inherited);
        for (const rel of ['bolder', 'lighter']) {
            el.setAttribute('style', 'font-weight:' + rel);
            out[inherited + ' ' + rel] = String(getComputedStyle(el).fontWeight);
        }
    }
    el.remove();
    parent.remove();
    return out;
})();
