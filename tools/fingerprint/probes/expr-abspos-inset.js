// What an absolutely positioned box with `inset` resolves to. Chrome expands an
// abspos box against its containing block when both insets on an axis are given
// and the size is auto; iphey's geometry probe hangs its 100x100 test box inside
// exactly such a host (`position:absolute; inset:0`), so the host's box decides
// where every rect it reads lands.
(() => {
    const out = {};
    const read = (label, el) => {
        const r = el.getBoundingClientRect();
        out[label] = {
            rect: [r.x, r.y, r.width, r.height].map((n) => Math.round(n * 100) / 100),
            offset: [el.offsetLeft, el.offsetTop, el.offsetWidth, el.offsetHeight],
            client: [el.clientWidth, el.clientHeight],
            computed: (() => {
                const c = getComputedStyle(el);
                return [c.top, c.right, c.bottom, c.left, c.width, c.height];
            })(),
        };
    };

    const cases = {
        inset0: 'position:absolute; inset:0;',
        topBottom: 'position:absolute; top:10px; bottom:20px; left:5px; right:7px;',
        onlyVertical: 'position:absolute; top:0; bottom:0; width:40px;',
        onlyHorizontal: 'position:absolute; left:0; right:0; height:40px;',
        insetWithWidth: 'position:absolute; inset:0; width:50px; height:60px;',
        insetPct: 'position:absolute; top:10%; bottom:10%; left:25%; right:25%;',
        insetNegative: 'position:absolute; inset:-10px;',
        fixedInset0: 'position:fixed; inset:0;',
    };
    for (const [label, css] of Object.entries(cases)) {
        const el = document.createElement('div');
        el.setAttribute('style', css + ' visibility:hidden;');
        document.body.appendChild(el);
        read(label, el);
        el.remove();
    }

    // Nested: an inset:0 host is the containing block for its abspos child, so
    // the child's left:-9999px is measured from the host's padding edge.
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute; inset:0; pointer-events:none;');
    const child = document.createElement('div');
    child.setAttribute('style', 'position:absolute; top:0; left:-9999px; width:100px; height:100px; visibility:hidden;');
    host.appendChild(child);
    document.body.appendChild(host);
    read('nestedHost', host);
    read('nestedChild', child);
    host.remove();

    out.viewport = [window.innerWidth, window.innerHeight];
    return out;
})()
