// What getComputedStyle reports for the four insets. Chrome resolves an inset
// at LAYOUT time, so a positioned element's computed `left` is the used offset
// in pixels -- even where the declaration is `auto` or a percentage -- while an
// unpositioned one reports the declaration as written. Which of those two a
// `relative` or a `sticky` box takes is the part worth measuring.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute; top:0; left:0; width:400px; height:200px;');
    document.body.appendChild(host);

    const read = (label, css, parent) => {
        const el = document.createElement('div');
        el.setAttribute('style', css);
        (parent ?? host).appendChild(el);
        const c = getComputedStyle(el);
        out[label] = [c.top, c.right, c.bottom, c.left, c.position, c.width, c.height];
        el.remove();
    };

    for (const position of ['static', 'relative', 'absolute', 'fixed', 'sticky']) {
        const base = `position:${position}; width:50px; height:30px;`;
        read(position + 'Bare', base);
        read(position + 'Px', base + ' top:10px; left:20px;');
        read(position + 'Pct', base + ' top:10%; left:25%;');
        read(position + 'FarOnly', base + ' right:10px; bottom:20px;');
        read(position + 'All', base + ' top:1px; right:2px; bottom:3px; left:4px;');
        read(position + 'Auto', base + ' top:auto; left:auto; right:auto; bottom:auto;');
    }

    // No box at all: a `display:none` element has nothing for a used value to
    // be about.
    read('noneAbsolute', 'position:absolute; display:none; top:10%; left:25%; width:50px; height:30px;');
    // A box with no size of its own, so the far edge is the near edge's
    // complement less nothing.
    read('emptyAbsolute', 'position:absolute; top:10px; left:20px;');

    out.hostBox = (() => {
        const r = host.getBoundingClientRect();
        return [r.x, r.y, r.width, r.height];
    })();
    out.viewport = [window.innerWidth, window.innerHeight];
    host.remove();
    return out;
})()
