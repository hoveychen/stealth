// The two remaining test files the finer grid step moves, read rather than
// derived.
//
// `css/specified_precision.html` is the parent plan's precision battery -- 21
// widths chosen to separate the f32 and f64 models at a 1/64 step, plus a second
// block checking that a rule, a style attribute and an `em` all reach the same
// number. `element/box_measure_loops.html` chains eight `padding: 1%` boxes, so
// the innermost width is eight percentage resolutions each snapped in turn --
// the case where a grid step compounds.
//
// Both are read here with the same markup those files build, so the rewrite is a
// transcription. Run HEADLESS at each factor: the battery sits inside a
// `width:1000px` wrapper and does not care about the viewport, but the padding
// chain resolves against the body, and run-expr's default `--window-size
// 1920,1080` gives headless the same 1904px body the test server serves. (Headed
// would not: the window opens at the display's size, which was 1512 wide here.)
// `documentElement.clientWidth` is reported so that assumption is visible in the
// reading rather than assumed.
(() => {
    const out = { dpr: String(window.devicePixelRatio), viewport: String(document.documentElement.clientWidth) };
    const host = document.createElement('div');
    document.body.appendChild(host);

    // --- specified_precision.html, block 1 -----------------------------------
    const measure = (decl) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div style="width:1000px"><div data-m style="width:' + decl + 'px">x</div></div>';
        host.appendChild(wrap);
        const el = wrap.querySelector('[data-m]');
        const o = {
            css: String(getComputedStyle(el).width),
            rect: String(el.getBoundingClientRect().width),
            style: String(el.style.width),
        };
        wrap.remove();
        return o;
    };
    const AUTHORED = [
        '465.5466592', '100.0156249', '100.0156251', '33.33333333333333', '465.53125',
        '12.3456789', '7.0156249', '250.0078124', '250.0078126', '3.9999999',
        '64.0156249', '199.9843751', '0.0156249', '1000.0156249', '77.7777777',
        '1.0000001', '1.9999999', '300.0000001', '0.30000001', '511.9843751',
        '512.0156249',
    ];
    for (const decl of AUTHORED) {
        const m = measure(decl);
        out['case.' + decl] = [m.css, m.rect, m.style].join(' | ');
    }

    // --- specified_precision.html, block 2 -----------------------------------
    const sheet = document.createElement('style');
    sheet.textContent = '.pw{width:465.5466592px} .pm{margin-left:465.5466592px} .pp{padding-left:465.5466592px}';
    document.head.appendChild(sheet);
    const read = (cls, decl) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = '<div style="width:1000px"><div data-m class="' + cls + '" style="' + decl + '">x</div></div>';
        host.appendChild(wrap);
        const el = wrap.querySelector('[data-m]');
        const cs = getComputedStyle(el);
        const o = [el.getBoundingClientRect().width, cs.width, cs.marginLeft, cs.paddingLeft].join(' ');
        wrap.remove();
        return o;
    };
    out['route.rule width'] = read('pw', '');
    out['route.attr width'] = read('', 'width:465.5466592px');
    out['route.rule margin'] = read('pm', '');
    out['route.attr margin'] = read('', 'margin-left:465.5466592px');
    out['route.rule padding'] = read('pp', '');
    out['route.attr padding'] = read('', 'padding-left:465.5466592px');
    out['route.em'] = read('', 'font-size:10px;width:46.55466592em');
    sheet.remove();

    // --- box_measure_loops.html, the eight-deep 1% padding chain -------------
    {
        const root = document.createElement('div');
        host.appendChild(root);
        let leaf = root;
        for (let i = 0; i < 8; i++) {
            const box = document.createElement('div');
            box.style.padding = '1%';
            leaf.appendChild(box);
            leaf = box;
        }
        leaf.textContent = 'x';
        out['chain.clientWidth'] = String(leaf.clientWidth);
        out['chain.offsetWidth'] = String(leaf.offsetWidth);
        out['chain.scrollWidth'] = String(leaf.scrollWidth);
        out['chain.computed'] = String(getComputedStyle(leaf).width);
        out['chain.rect'] = String(leaf.getBoundingClientRect().width);
        root.remove();
    }

    host.remove();
    return out;
})();
