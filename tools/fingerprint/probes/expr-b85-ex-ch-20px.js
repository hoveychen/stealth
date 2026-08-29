// The exact computed strings for `ex` and `ch` at font-size 20px.
//
// computed_relative_units.html asserts on the string a computed style prints,
// so the expected values have to be Chrome's strings and not a ratio this
// engine's own table implies -- deriving them from the table would assert the
// table against itself.
//
// Run headed: which font a generic family resolves to is the window system's
// answer, and a headless Chrome resolves serif, sans-serif and monospace to the
// same face. Also pass --chrome-arg --force-device-scale-factor=2.
(() => {
    const host = document.createElement('div');
    document.body.appendChild(host);
    const out = {};
    for (const fam of ['serif', 'sans-serif', 'monospace', 'Arial', 'Georgia', 'Verdana']) {
        for (const unit of ['ex', 'ch']) {
            host.innerHTML = `<div style="width:400px;font-size:20px"><p style="font-family:${fam};padding-top:2${unit}">x</p></div>`;
            const p = host.firstChild.firstChild;
            out[`${fam}/2${unit}`] = {
                paddingTop: getComputedStyle(p).paddingTop,
                resolved: getComputedStyle(p).fontFamily,
            };
        }
    }
    host.remove();
    return JSON.stringify(out, null, 1);
})()
