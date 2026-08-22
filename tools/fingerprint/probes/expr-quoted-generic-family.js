// A generic font family is a CSS keyword, so quoting it turns it into an
// ordinary family name — one no system has installed, which falls back to the
// default font. `font-family: monospace` and `font-family: 'monospace'` must
// therefore measure differently in exactly one direction: the quoted form
// should match an arbitrary unknown family, not the generic.
(() => {
    const el = document.createElement('span');
    el.style.cssText = 'position:absolute;left:-9999px;font-size:72px;';
    el.textContent = 'mmmmmmmmmmlli';
    document.body.appendChild(el);
    const w = (css) => {
        el.style.fontFamily = '';
        el.style.fontFamily = css;
        return { css, width: el.offsetWidth, computed: getComputedStyle(el).fontFamily };
    };
    const out = [
        w('monospace'),
        w("'monospace'"),
        w('"monospace"'),
        w('sans-serif'),
        w("'sans-serif'"),
        w('serif'),
        w("'serif'"),
        w("'NoSuchFamilyAtAll'"),
        w('NoSuchFamilyAtAll'),
    ];
    el.remove();
    return JSON.stringify(out);
})()
