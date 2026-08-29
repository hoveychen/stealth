// How does the computed `font-family` come back out?
//
// B59 read the Cloudflare widget's payload and saw us serialise a family name
// containing a space without quotes where Chrome quotes it. This asks both arms
// the same question over the shapes the difference could hide in: a bare
// identifier, two identifiers with a space, an already-quoted name, a list, and
// the generic keywords (which must never be quoted).
(() => {
    const cases = [
        'Arial',
        'Adwaita Sans',
        '"Adwaita Sans"',
        "'Adwaita Sans'",
        'Adwaita Sans, serif',
        'serif',
        'sans-serif',
        'system-ui',
        'Times New Roman, Times, serif',
        '"has \\"quote\\"", monospace',
        'A B C',
    ];
    const out = {};
    const d = document.createElement('div');
    document.body.appendChild(d);
    for (const c of cases) {
        d.style.fontFamily = '';
        d.style.fontFamily = c;
        out[c] = {
            inline: d.style.fontFamily,
            computed: getComputedStyle(d).fontFamily,
        };
    }
    d.remove();
    return out;
})()
