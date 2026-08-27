// The exact markup `tests/element/text_advance_grid.html` builds, read off
// headed Chrome so the test is a transcription rather than arithmetic.
//
// Every case the test asserts is here, in the same order, built the same way --
// including the two the test cannot assert (a kerned string and a flex item's
// automatic minimum size), so what is left out is left out on the record.
//
// Run headed and at `--force-device-scale-factor=2`: that is the device scale
// this engine claims through devicePixelRatio, and the grid is the device
// pixel's.
(() => {
    const out = {};
    const host = document.createElement('div');
    document.body.appendChild(host);
    const shrink = 'position:absolute;left:0;top:0;white-space:pre;';
    const box = (style, build) => {
        const el = document.createElement('div');
        el.setAttribute('style', shrink + style);
        build(el);
        host.appendChild(el);
        return el;
    };
    const text = (s) => (el) => el.appendChild(document.createTextNode(s));

    const four = (what, style, content) => {
        const el = box(style, text(content));
        out[what + '.rect'] = String(el.getBoundingClientRect().width);
        out[what + '.computed'] = String(getComputedStyle(el).width);
        out[what + '.offsetWidth'] = String(el.offsetWidth);
        out[what + '.clientWidth'] = String(el.clientWidth);
        out[what + '.scrollWidth'] = String(el.scrollWidth);
        el.remove();
    };

    four('aaa', '', 'aaa');
    four('word', '', 'word');
    four('aaa bbb', '', 'aaa bbb');
    four('aaa bbb ccc', '', 'aaa bbb ccc');
    four('ten words', '', 'long word '.repeat(10));
    four('a x1000', '', 'a'.repeat(1000));
    four('12px', 'font-size:12px', 'aaa bbb ccc');
    four('14px', 'font-size:14px', 'aaa bbb ccc');
    four('24px', 'font-size:24px', 'aaa bbb ccc');

    {
        const one = box('font-size:13px', text('aaa'));
        const three = box('font-size:13px', (el) => {
            el.appendChild(document.createTextNode('a'));
            el.appendChild(document.createTextNode('a'));
            el.appendChild(document.createTextNode('a'));
        });
        out['one node.rect'] = String(one.getBoundingClientRect().width);
        out['three nodes.rect'] = String(three.getBoundingClientRect().width);
        one.remove();
        three.remove();
    }

    {
        const holder = box('', (el) => { el.innerHTML = '<span data-s>aaa</span>'; });
        const span = holder.querySelector('[data-s]');
        out['inline span.rect'] = String(span.getBoundingClientRect().width);
        out['inline span.offsetWidth'] = String(span.offsetWidth);
        holder.remove();
    }

    // The automatic minimum size of a flex item, both with the shrink wrapper's
    // `white-space: pre` inherited and with it turned back off -- the first
    // cannot break lines, so its min-content is the whole string, and only the
    // second is the longest-word case `minContentWidth` models.
    for (const [name, extra] of [['pre', ''], ['normal', 'white-space:normal']]) {
        const row = box('display:flex;width:10px', (el) => {
            const item = document.createElement('div');
            item.setAttribute('style', 'flex:1;' + extra);
            item.textContent = 'aaa bbb ccc';
            el.appendChild(item);
        });
        const item = row.firstChild;
        out['flex min ' + name + '.rect'] = String(item.getBoundingClientRect().width);
        out['flex min ' + name + '.offsetWidth'] = String(item.offsetWidth);
        row.remove();
    }
    // The longest word on its own, for comparison with the flex answer.
    four('aaa alone', 'font-size:16px', 'aaa');
    four('ccc alone', 'font-size:16px', 'ccc');

    host.remove();
    return out;
})();
