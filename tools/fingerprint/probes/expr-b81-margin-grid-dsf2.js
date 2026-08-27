// The two remaining test files whose numbers move with the grid step, read
// rather than derived.
//
// `css/margin_percentage.html` asserts a percentage margin and the remainder of
// the line beside it, and `element/box_parts.html` explains why it uses 25%
// rather than 10% of the viewport line. Both were written against a 1/64 CSS
// pixel grid; the grid is 1/64 of a device pixel, so at the scale factor this
// engine claims they need the finer step. This reads the exact markup each of
// them builds, so the rewrite is a transcription.
//
// Run headed with `--chrome-arg --force-device-scale-factor=2`.
(() => {
    const out = { dpr: String(window.devicePixelRatio) };
    const host = document.createElement('div');
    document.body.appendChild(host);

    // margin_percentage.html's named case: the margin, the four sides, the
    // remainder the box keeps, and its integer reading.
    {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div style="width:400px"><div data-m style="margin-left:33.3%">x</div></div>';
        host.appendChild(wrap);
        const el = wrap.querySelector('[data-m]');
        const cs = getComputedStyle(el);
        out['margin.left'] = cs.marginLeft;
        out['margin.right'] = cs.marginRight;
        out['margin.top'] = cs.marginTop;
        out['margin.bottom'] = cs.marginBottom;
        out['margin.width'] = cs.width;
        out['margin.offsetWidth'] = String(el.offsetWidth);
        out['margin.rect'] = String(el.getBoundingClientRect().width);
        wrap.remove();
    }

    // box_parts.html's percentage padding, and the 10% case its comment cites
    // as the reason it picked 25%.
    for (const pct of ['25%', '10%']) {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div data-m style="width:400px;padding:' + pct + '">x</div>';
        host.appendChild(wrap);
        const el = wrap.querySelector('[data-m]');
        const cs = getComputedStyle(el);
        out['pad' + pct + '.left'] = cs.paddingLeft;
        out['pad' + pct + '.top'] = cs.paddingTop;
        out['pad' + pct + '.width'] = cs.width;
        out['pad' + pct + '.clientWidth'] = String(el.clientWidth);
        out['pad' + pct + '.offsetWidth'] = String(el.offsetWidth);
        out['pad' + pct + '.clientHeight'] = String(el.clientHeight);
        wrap.remove();
    }
    // And the bare 10% of the viewport line, which is the number the comment
    // quotes.
    {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div data-m style="width:10%">x</div>';
        host.appendChild(wrap);
        const el = wrap.querySelector('[data-m]');
        out['line10.width'] = getComputedStyle(el).width;
        out['line10.rect'] = String(el.getBoundingClientRect().width);
        out['line10.clientWidth'] = String(document.documentElement.clientWidth);
        wrap.remove();
    }

    host.remove();
    return out;
})();
