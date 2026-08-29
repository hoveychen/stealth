// What a parent's height counts of its children's boxes.
//
// `Element.contentHeight` adds `el.getElementDimensions(frame).height` per
// child, and that field is the child's CONTENT height: not its padding, not
// its border, and not what its own children put in it. Three readings off the
// margin-collapse work said so -- a nested block was 0 against Chrome's 12 --
// and this is the full sweep behind the one-line plan those readings opened.
//
// Everything is read off the outer parent's offsetHeight, because that is the
// number a guard takes; the child's own box is asserted beside it in the cases
// where the two should differ, so a fix that moves the parent by breaking the
// child is visible here rather than three tests later.
(() => {
    const out = {};
    const host = document.createElement('div');
    host.setAttribute('style', 'position:absolute;top:0;left:0;width:400px');
    document.body.appendChild(host);

    const measure = (name, html) => {
        const wrap = document.createElement('div');
        wrap.innerHTML = html;
        host.appendChild(wrap);
        const p = wrap.querySelector('[data-p]');
        out[name] = String(p.offsetHeight);
        const k = wrap.querySelector('[data-k]');
        if (k) out[name + '.child'] = String(k.offsetHeight);
        wrap.remove();
    };

    // The child's own content, one and two levels down. A parent that adds only
    // `dims.height` answers 0 for both, because nothing sized either wrapper.
    measure('nested1', '<div data-p><div data-k><div style="height:12px"></div></div></div>');
    measure('nested2', '<div data-p><div data-k><div><div style="height:12px"></div></div></div></div>');
    // ...and the same with text at the bottom rather than a sized box, since
    // the line-box path and the block path are different code.
    measure('nestedText', '<div data-p><div data-k><div>x</div></div></div>');

    // The child's own edges. Both are outside its content height and both are
    // inside the parent's.
    measure('childPad', '<div data-p><div data-k style="height:12px;padding:5px"></div></div>');
    measure('childBorder', '<div data-p><div data-k style="height:12px;border:3px solid"></div></div>');
    measure('childBoth', '<div data-p><div data-k style="height:12px;padding:5px;border:3px solid"></div></div>');
    // Padding with no declared height: the padding is all there is.
    measure('childPadOnly', '<div data-p><div data-k style="padding:5px"></div></div>');

    // border-box changes which side of the declaration the padding is on, so
    // the child is 12 tall in total rather than 22.
    measure('childBorderBox',
        '<div data-p><div data-k style="height:12px;padding:5px;box-sizing:border-box"></div></div>');

    // Two children, so a fix that double-counts one shows up as a doubled
    // number rather than a plausible one.
    measure('twoPadded', '<div data-p><div data-k style="height:12px;padding:5px"></div>' +
        '<div style="height:12px;padding:5px"></div></div>');

    // The interaction with margin collapsing, which landed just before this: a
    // padded child is NOT self-collapsing, so its margins do not join across
    // it. 10 + 22 + 10 + 12, with the outer two escaping: 44.
    measure('paddedNotSelfCollapsing',
        '<div data-p><div data-k style="height:12px;padding:5px;margin:10px 0"></div>' +
        '<div style="height:12px;margin:10px 0"></div></div>');

    // A child that is its own formatting context still contributes its whole
    // border box.
    measure('childBfc',
        '<div data-p><div data-k style="overflow:hidden;padding:5px"><div style="height:12px"></div></div></div>');

    host.remove();
    return out;
})()
