// Which CSS properties clamp their computed value, and where the clamp lands.
//
// `opacity: 1.015625` computes to `1` in Chrome and to `1.01562` here. That is
// one property; a fix built on one property would leave every sibling wrong, so
// this asks the whole family at once: specified value (`el.style.x`) beside
// computed value, over-range and under-range, for every property with a range
// in its grammar.
(() => {
    const out = {};
    const host = document.createElement('div');
    document.body.appendChild(host);

    const probe = (prop, value) => {
        const el = document.createElement('div');
        el.style.setProperty(prop, value);
        host.appendChild(el);
        const specified = el.style.getPropertyValue(prop);
        const computed = getComputedStyle(el).getPropertyValue(prop);
        el.remove();
        return { specified, computed };
    };

    const CASES = [
        ['opacity', ['1.015625', '-0.5', '0.5', '2']],
        ['fill-opacity', ['1.015625', '-0.5']],
        ['stroke-opacity', ['1.015625', '-0.5']],
        ['stop-opacity', ['1.015625', '-0.5']],
        ['flood-opacity', ['1.015625', '-0.5']],
        ['shape-image-threshold', ['1.015625', '-0.5']],
        ['font-weight', ['1200', '0.5']],
        ['z-index', ['3.7', '-2']],
        ['order', ['3.7']],
        ['column-count', ['0', '2.5']],
        ['orphans', ['0', '2.5']],
        ['widows', ['0', '2.5']],
        ['tab-size', ['-2', '2.5']],
        ['flex-grow', ['-1', '1.015625']],
        ['flex-shrink', ['-1', '1.015625']],
        ['line-height', ['-1', '1.015625']],
        ['-webkit-line-clamp', ['0', '2.5']],
        ['border-top-width', ['-1px', '1.015625px']],
        ['font-size', ['-1px', '1.015625px']],
        ['width', ['-1px', '1.015625px']],
        ['letter-spacing', ['1.015625px']],
        ['scale', ['1.015625']],
    ];
    for (const [prop, values] of CASES) {
        for (const v of values) {
            const r = probe(prop, v);
            out[`${prop}: ${v}`] = `spec=${JSON.stringify(r.specified)} computed=${JSON.stringify(r.computed)}`;
        }
    }
    host.remove();
    return JSON.stringify(out, null, 1);
})()
