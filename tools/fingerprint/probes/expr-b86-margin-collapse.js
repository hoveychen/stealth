// What margin collapsing actually does, measured rather than derived.
//
// The plan this belongs to cited two readings in `scratch/` -- both gone, the
// directory does not survive a restart -- so the numbers have to be taken
// again. It deliberately does not test one shape and generalise: adjacent
// siblings, a first/last child escaping its parent, and an empty block
// collapsing through itself are three different rules and an engine can get
// any one of them right while getting the others wrong.
//
// Every height is read off the parent rather than off a child, because the
// parent's height is where a missing collapse shows up as a number a guard can
// see. Positions are relative to the parent's own border box so the body's
// default 8px margin does not appear in any answer.
(() => {
    const out = {};
    const host = document.createElement('div');
    // No border and no padding on the host: it must not interfere with the
    // parent/child collapses being measured one level down.
    host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
    document.body.appendChild(host);

    const measure = (name, html) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = html;
        host.appendChild(wrap);
        const p = wrap.querySelector('[data-p]');
        out[name + '.parentHeight'] = String(p.offsetHeight);
        out[name + '.parentRectHeight'] = String(p.getBoundingClientRect().height);
        const pTop = p.getBoundingClientRect().top;
        const kids = wrap.querySelectorAll('[data-k]');
        const tops = [];
        for (const k of kids) tops.push(String(k.getBoundingClientRect().top - pTop));
        out[name + '.kidTops'] = tops.join(',');
        // Where the parent itself landed, which is what a first-child margin
        // that escapes moves.
        out[name + '.parentTop'] = String(pTop - host.getBoundingClientRect().top);
        wrap.remove();
    };

    const B = 'height:12px;background:#000';

    // 1. Three adjacent siblings, 10px above and below each. Collapsed, the two
    //    gaps are 10 rather than 20; the outer two escape the parent entirely.
    measure('siblings', '<div data-p><div data-k style="' + B + ';margin:10px 0"></div>' +
        '<div data-k style="' + B + ';margin:10px 0"></div>' +
        '<div data-k style="' + B + ';margin:10px 0"></div></div>');

    // 2. Unequal adjacent margins: the collapsed gap is the larger, not the sum.
    measure('unequal', '<div data-p><div data-k style="' + B + ';margin-bottom:30px"></div>' +
        '<div data-k style="' + B + ';margin-top:10px"></div></div>');

    // 3. A negative margin against a positive one: the rule is max(positives)
    //    plus min(negatives), which no amount of "take the larger" reproduces.
    measure('negative', '<div data-p><div data-k style="' + B + ';margin-bottom:30px"></div>' +
        '<div data-k style="' + B + ';margin-top:-10px"></div></div>');

    // 4. First child's top margin escapes a parent with no border and no
    //    padding -- the parent moves down and does NOT grow.
    measure('escapeTop', '<div data-p><div data-k style="' + B + ';margin-top:20px"></div></div>');

    // 5. The same parent with a 1px border: nothing escapes, and the border
    //    adds 2 to the height.
    measure('borderTop', '<div data-p style="border:1px solid #000">' +
        '<div data-k style="' + B + ';margin-top:20px"></div></div>');

    // 6. And with padding instead of a border.
    measure('paddingTop', '<div data-p style="padding-top:1px">' +
        '<div data-k style="' + B + ';margin-top:20px"></div></div>');

    // 7. Last child's bottom margin escapes the same way.
    measure('escapeBottom', '<div data-p><div data-k style="' + B + ';margin-bottom:20px"></div></div>');

    // 8. An empty block with margins on both sides collapses through itself, so
    //    the two blocks around it are 10 apart, not 20 and not 30.
    measure('emptyThrough', '<div data-p><div data-k style="' + B + '"></div>' +
        '<div style="margin:10px 0"></div>' +
        '<div data-k style="' + B + '"></div></div>');

    // 9. A parent whose own height is auto and whose only content is a margin:
    //    the parent collapses to zero.
    measure('emptyParent', '<div data-p><div style="margin:10px 0"></div></div>');

    // 10. Collapsing does not happen across a block formatting context.
    measure('bfc', '<div data-p style="overflow:hidden">' +
        '<div data-k style="' + B + ';margin-top:20px"></div></div>');

    host.remove();
    return out;
})()
