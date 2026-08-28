// The three declarations Kasada writes on x-hyatt, verbatim.
//
// Logged off the live station with the `units-set-log` knob:
//   position:absolute;width:1.03in;height:1.03in
//   position:absolute;width:2.6162cm;height:2.6162cm
//   position:absolute;width:74.16pt;height:74.16pt
// 1.03in, 2.6162cm and 74.16pt are the same 98.88px in three unit systems, so
// the reading the guard takes is whether one length survives three conversions.
(() => {
    const out = { triple: {}, agree: null };
    const d = document.createElement('div');
    document.documentElement.appendChild(d);
    for (const css of ['position:absolute;width:1.03in;height:1.03in',
        'position:absolute;width:2.6162cm;height:2.6162cm',
        'position:absolute;width:74.16pt;height:74.16pt']) {
        d.style.cssText = css;
        const cs = getComputedStyle(d);
        const r = d.getBoundingClientRect();
        out.triple[css.split(';')[1]] = {
            computedWidth: cs.width,
            computedHeight: cs.height,
            rectWidth: r.width,
            offsetWidth: d.offsetWidth,
        };
    }
    const widths = Object.values(out.triple).map((v) => v.computedWidth);
    out.agree = new Set(widths).size === 1 ? 'all three agree: ' + widths[0]
        : 'DISAGREE: ' + widths.join(' / ');
    d.remove();
    return JSON.stringify(out, null, 1);
})()
