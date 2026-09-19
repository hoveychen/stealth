// A flex item's `auto` margin absorbs the container's free space, on BOTH axes
// and before `justify-content` or `align-items` get a say. `margin-left:auto`
// on the last item is how a toolbar pushes one control to the far end, and
// `margin:auto` is how a flex child centres itself -- so this is a layout the
// web writes on purpose, not a corner.
//
// Read in a 400x200 flex container. The block-flow rule is the other file,
// tools/fingerprint/probes/expr-auto-margin-used.js: there a vertical `auto`
// margin is always 0, because a block formatting context hands out no vertical
// free space. A flex container does, which is what separates the two.
//
// Also carries the one out-of-flow shape the block-flow probe left open: an
// absolute box that declares NO inset takes its static position, and its own
// margin moves it from there on both axes.
(() => {
    const out = {};
    const M = ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'];
    const read = (label, hostCss, css, extra) => {
        const host = document.createElement('div');
        host.setAttribute('style', hostCss);
        document.body.appendChild(host);
        if (extra) host.innerHTML = extra;
        const el = document.createElement('div');
        el.setAttribute('style', css);
        host.appendChild(el);
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect(), hr = host.getBoundingClientRect();
        out[label] = M.map((n) => cs.getPropertyValue(n)).join(' | ') +
            '  @' + Math.round((r.x - hr.x) * 100) / 100 + ',' + Math.round((r.y - hr.y) * 100) / 100;
        host.remove();
    };
    const ROW = 'display:flex; width:400px; height:200px; margin:0';
    const COL = 'display:flex; flex-direction:column; width:400px; height:200px; margin:0';
    const BOX = 'width:100px; height:20px;';

    read('rowAll', ROW, BOX + ' margin:auto');
    read('rowSides', ROW, BOX + ' margin-left:auto; margin-right:auto');
    read('rowLeft', ROW, BOX + ' margin-left:auto');
    read('rowRight', ROW, BOX + ' margin-right:auto');
    read('rowTopBottom', ROW, BOX + ' margin-top:auto; margin-bottom:auto');
    read('rowTop', ROW, BOX + ' margin-top:auto');
    read('rowMixed', ROW, BOX + ' margin-left:auto; margin-right:10px');
    read('rowWithSibling', ROW, BOX + ' margin-left:auto',
         '<div style="width:100px;height:20px"></div>');
    read('colAll', COL, BOX + ' margin:auto');
    read('colTop', COL, BOX + ' margin-top:auto');
    read('rowNoAuto', ROW, BOX + ' margin:5px');
    // Out of flow inside a flex container is NOT a flex item.
    read('rowAbsolute', ROW, BOX + ' position:absolute; margin:auto');

    // The static-position shape: an absolute box with no inset at all.
    const REL = 'position:relative; width:400px; height:200px; margin:0';
    read('absNoInset', REL, BOX + ' position:absolute; margin-left:30px; margin-top:12px');
    read('absNoInsetAuto', REL, BOX + ' position:absolute; margin:auto');
    read('absNoInsetAfterFlow', REL, BOX + ' position:absolute; margin-top:12px',
         '<div style="height:40px"></div>');
    read('absTopOnlyStaticX', REL, BOX + ' position:absolute; top:0; margin-left:30px; margin-top:12px');
    return out;
})()
