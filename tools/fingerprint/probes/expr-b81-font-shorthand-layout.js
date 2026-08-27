// Does the `font` shorthand reach the layout's font, or only the canvas?
//
// Found while measuring `text-advance-64th-grid`: over an 18-size sweep with
// `style="font:<n>px serif"`, this engine answered the SAME width for every
// size -- the width of 16px serif, the default -- while its own
// `measureText` answered each size correctly. So the shorthand reaches the
// canvas font and not the box.
//
// This separates the two candidates: the shorthand not expanding into
// `font-size` / `font-family` for the cascade at all, versus the layout not
// reading those longhands. Each row sets the same 13px serif two ways and reads
// the box, the computed longhands, and (for the shorthand row) what the
// shorthand itself reads back.
(() => {
    const out = {};
    const mk = (style, text) => {
        const el = document.createElement('div');
        el.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;' + style);
        el.textContent = text;
        document.documentElement.appendChild(el);
        return el;
    };
    const read = (name, style) => {
        const el = mk(style, 'aaa bbb ccc');
        const cs = getComputedStyle(el);
        out[name + '.rect'] = String(el.getBoundingClientRect().width);
        out[name + '.offset'] = String(el.offsetWidth);
        out[name + '.fontSize'] = cs.fontSize;
        out[name + '.fontFamily'] = cs.fontFamily;
        out[name + '.fontWeight'] = cs.fontWeight;
        out[name + '.font'] = cs.font;
        out[name + '.height'] = String(el.getBoundingClientRect().height);
        el.remove();
    };

    read('shorthand', 'font:13px serif');
    read('longhand', 'font-size:13px;font-family:serif');
    read('sizeOnly', 'font-size:13px');
    read('familyOnly', 'font-family:monospace');
    read('shorthandMono', 'font:13px monospace');
    read('shorthandBold', 'font:bold 16px serif');
    read('weightLonghand', 'font-weight:bold');
    // A stylesheet rule rather than an inline style, in case the two paths
    // differ.
    const sheet = document.createElement('style');
    sheet.textContent = '.b81sheet { font: 13px serif }';
    document.documentElement.appendChild(sheet);
    const el = mk('', 'aaa bbb ccc');
    el.className = 'b81sheet';
    out['sheet.rect'] = String(el.getBoundingClientRect().width);
    out['sheet.fontSize'] = getComputedStyle(el).fontSize;
    el.remove();
    sheet.remove();

    return out;
})();
