// What a scroll container's scrollWidth counts of its children.
//
// `Element.contentWidth` lays every visible in-flow child end to end on one
// row and sums their widths, and its comment says why: the engine cannot see
// the layout mode, and a page that appends children until `scrollWidth` passes
// a threshold never terminates if the metric ignores what was just inserted.
// Three 400px block children in a 400px box therefore answer 1200 here.
//
// That comment predates `CSSStyleDeclaration.resolvedDisplay`, so the premise
// ("we can't detect the layout mode") is worth retesting -- but first the
// question this probe exists for: what does Chrome answer for each
// arrangement, and is the marquee idiom actually served by the summing, or
// only by the arrangements where Chrome sums too?
//
// Everything is read off the parent, because that is the number a guard takes.
// `scrollWidth` and `clientWidth` are read together: they share
// `getElementDimensions`, and a change that fixes one by breaking the other has
// to be visible here rather than three tests later.
(() => {
    const out = {};
    // Asserted in the same run, not assumed: the layout grid is 1/64 of a
    // DEVICE pixel, so a Chrome arm left at dsf=1 reads a different grid than
    // this engine's dpr=2 persona ([[chrome-arm-needs-persona-dpr]],
    // [[assert-dpr-in-the-same-run]]).
    out.dpr = String(window.devicePixelRatio);
    out.viewport = `${window.innerWidth}x${window.innerHeight}`;
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
    document.body.appendChild(host);

    const measure = (name, html) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = html;
        host.appendChild(wrap);
        const p = wrap.querySelector('[data-p]');
        out[name] = `sw=${p.scrollWidth} cw=${p.clientWidth} ow=${p.offsetWidth}`;
        wrap.remove();
    };

    // `box-sizing` is pinned on every box here, parent and child. The page the
    // two arms share carries a Tailwind-style reset, and with `border-box` in
    // the cascade Chrome answered `cw=400` for a `width:400px;padding:5px`
    // parent while this engine -- which does not take box-sizing from a
    // stylesheet -- answered 410. That is a real difference and a different
    // one; leaving it in this probe would put it in every padded row.
    const BS = 'box-sizing:content-box';
    const W = `${BS};width:400px;height:20px`;
    const N = `${BS};width:50px;height:20px`;

    // The case in the plan: block children stack vertically, so the scrollable
    // area is one child wide, not three.
    measure('blockChildren1', `<div data-p style="${BS};width:400px"><div style="${W}"></div></div>`);
    measure('blockChildren3', `<div data-p style="${BS};width:400px"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    // Wider than the container, so the overflow is real and one child deep.
    measure('blockOverflow3', `<div data-p style="${BS};width:200px"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    // With padding, since the scrollable area includes it.
    measure('blockPadded3', `<div data-p style="${BS};width:400px;padding:5px"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    // Narrow block children: nothing overflows, so the answer is the container
    // either way -- an engine that sums answers 150 here and Chrome answers 400.
    measure('blockNarrow3', `<div data-p style="${BS};width:400px"><div style="${N}"></div><div style="${N}"></div><div style="${N}"></div></div>`);

    // The arrangements that DO lay out on a row. If Chrome sums for these, the
    // marquee idiom is served without summing for block children.
    measure('inlineBlock3', `<div data-p style="${BS};width:200px;white-space:nowrap"><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div></div>`);
    measure('inlineBlockWrap3', `<div data-p style="${BS};width:200px"><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div></div>`);
    measure('flexRow3', `<div data-p style="${BS};width:200px;display:flex"><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div></div>`);
    measure('flexColumn3', `<div data-p style="${BS};width:200px;display:flex;flex-direction:column"><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div></div>`);
    measure('floatLeft3', `<div data-p style="${BS};width:200px"><div style="float:left;${W}"></div><div style="float:left;${W}"></div><div style="float:left;${W}"></div></div>`);
    // Floats that DO fit on one line, and a wrapping flex row: the two shapes
    // that separate "children are in a row" from "children fit in a row".
    measure('floatNarrow3', `<div data-p style="${BS};width:200px"><div style="float:left;${N}"></div><div style="float:left;${N}"></div><div style="float:left;${N}"></div></div>`);
    measure('flexRowWrap3', `<div data-p style="${BS};width:200px;display:flex;flex-wrap:wrap"><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div></div>`);
    measure('gridRows3', `<div data-p style="${BS};width:200px;display:grid"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    measure('gridColumns3', `<div data-p style="${BS};width:200px;display:grid;grid-auto-flow:column"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);

    // Which `white-space` values keep the strip on one line. `nowrap` and `pre`
    // are the two the spec says do not wrap, and `pre-wrap` is the control that
    // does -- but the branch is going into an engine, so it is measured.
    for (const ws of ['nowrap', 'pre', 'pre-wrap', 'pre-line', 'break-spaces', 'normal']) {
        measure('ws-' + ws, `<div data-p style="${BS};width:200px;white-space:${ws}"><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div><div style="display:inline-block;${W}"></div></div>`);
    }
    // ...and the same values with BLOCK children, which never share a line
    // whatever the white-space says.
    for (const ws of ['nowrap', 'pre']) {
        measure('wsBlock-' + ws, `<div data-p style="${BS};width:200px;white-space:${ws}"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    }
    // A flex row whose direction is reversed still lays them along the axis.
    measure('flexRowReverse3', `<div data-p style="${BS};width:200px;display:flex;flex-direction:row-reverse"><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div></div>`);
    measure('flexColumnReverse3', `<div data-p style="${BS};width:200px;display:flex;flex-direction:column-reverse"><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div><div style="${W};flex:0 0 auto"></div></div>`);
    measure('gridColumnDense3', `<div data-p style="${BS};width:200px;display:grid;grid-auto-flow:column dense"><div style="${W}"></div><div style="${W}"></div><div style="${W}"></div></div>`);
    // An inline-level child mixed in with block ones: the block one breaks the
    // line, so the row is not a row.
    measure('mixedInlineBlock', `<div data-p style="${BS};width:200px;white-space:nowrap"><div style="display:inline-block;${W}"></div><div style="${W}"></div><div style="display:inline-block;${W}"></div></div>`);

    // Out-of-flow children: the plan's sibling reading is that `scrollable`
    // counts them and `in_flow` does not.
    measure('absolute3', `<div data-p style="${BS};width:200px;position:relative"><div style="position:absolute;left:0;${W}"></div><div style="position:absolute;left:400px;${W}"></div><div style="position:absolute;left:800px;${W}"></div></div>`);

    // The marquee idiom itself, in the shape a page actually writes it: a
    // nowrap strip of inline-blocks that grows until scrollWidth passes the
    // container. Reported as the count it took, so an engine that never grows
    // reports the cap.
    {
        const strip = document.createElement('div');
        strip.setAttribute('style', 'width:200px;white-space:nowrap;overflow:auto');
        host.appendChild(strip);
        let n = 0;
        while (strip.scrollWidth <= 200 && n < 50) {
            const cell = document.createElement('span');
            cell.setAttribute('style', 'display:inline-block;width:100px;height:20px');
            strip.appendChild(cell);
            n++;
        }
        out.marqueeCells = `${n} cells, sw=${strip.scrollWidth}`;
        strip.remove();
    }
    // ...and with block children, which is the shape the summing was kept for.
    {
        const strip = document.createElement('div');
        strip.setAttribute('style', 'width:200px;overflow:auto');
        host.appendChild(strip);
        let n = 0;
        while (strip.scrollWidth <= 200 && n < 50) {
            const cell = document.createElement('div');
            cell.setAttribute('style', 'width:100px;height:20px');
            strip.appendChild(cell);
            n++;
        }
        out.marqueeBlocks = `${n} cells, sw=${strip.scrollWidth}`;
        strip.remove();
    }

    // The two elements a page reads most often, for reference: both are already
    // special-cased away from the sum.
    out.bodyScrollWidth = String(document.body.scrollWidth);
    out.docScrollWidth = String(document.documentElement.scrollWidth);

    host.remove();
    return out;
})()
