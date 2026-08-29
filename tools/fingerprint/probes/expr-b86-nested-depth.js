// A parent counts what its children's children put in them, at depth.
//
// The one-level case is in probes/expr-b86-child-box-height.js and is already
// known to be wrong here (a wrapper holding a 12px box measures 0). This asks
// the question the fix has to survive rather than the question it has to
// answer: a chain of N wrappers around one sized box, every level measured, so
// that a traversal which re-measures the subtree per level shows up as time
// rather than as a wrong number.
//
// Chrome answers the same thing at every level, and that is the point -- the
// box is 12px tall and nothing between it and the root adds anything.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
    document.body.appendChild(host);

    // A chain: <div><div>...<div style="height:12px"></div>...</div></div>
    const chain = (depth) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div>'.repeat(depth) + '<div style="height:12px" data-leaf></div>' +
            '</div>'.repeat(depth);
        host.appendChild(wrap);
        return wrap;
    };

    for (const depth of [1, 2, 4, 16, 64]) {
        const wrap = chain(depth);
        // Every level, not just the root: N measurements over the same
        // subtree is what separates "remembered once" from "walked again".
        const heights = [];
        let node = wrap.firstElementChild;
        while (node) {
            heights.push(node.offsetHeight);
            node = node.firstElementChild;
        }
        out['chain' + depth + '.levels'] = String(heights.length);
        out['chain' + depth + '.allTwelve'] = String(heights.every((h) => h === 12));
        out['chain' + depth + '.root'] = String(heights[0]);
        wrap.remove();
    }

    // Wide rather than deep, because the two multiply differently: 40 siblings
    // each holding a sized box, with the parent measured after each one.
    {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div data-p>' +
            '<div><div style="height:12px"></div></div>'.repeat(40) + '</div>';
        host.appendChild(wrap);
        const p = wrap.querySelector('[data-p]');
        let last = 0;
        for (let i = 0; i < 40; i++) last = p.offsetHeight;
        out['wide40.parent'] = String(last);
        wrap.remove();
    }

    host.remove();
    return out;
})()
