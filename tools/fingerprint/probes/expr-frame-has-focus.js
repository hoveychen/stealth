// Who answers true to `document.hasFocus()` when the focus is not theirs?
//
// The Cloudflare widget frame reads it (B60, `report-widget-box`): Chrome's
// cross-origin child frame answered `false` while ours answered `true`. A frame
// that always has focus is the classic headless tell, and it is the boolean
// shape this door was measured judging. Before changing the engine, this asks
// Chrome the same question: the top document, a freshly appended child frame,
// that child after an element inside it is focused, that child after the
// element is blurred, and then two sibling frames trading focus.
(() => {
    // about:blank has no <body> in this engine, so make one either way rather
    // than letting the two arms land on different pages.
    const root = document.documentElement ||
        document.appendChild(document.createElement('html'));
    const body = document.body || root.appendChild(document.createElement('body'));
    const out = { top: document.hasFocus() };
    const f = document.createElement('iframe');
    body.appendChild(f);
    const d = f.contentDocument;
    out.childBeforeFocus = d.hasFocus();
    out.topWhileChildBlurred = document.hasFocus();

    const inp = d.body && d.body.appendChild(d.createElement('input'));
    out.childInputFound = !!inp;
    if (inp) {
        inp.focus();
        out.childAfterFocus = d.hasFocus();
        out.topAfterChildFocus = document.hasFocus();
        out.childActiveIsInput = d.activeElement === inp;
        inp.blur();
        out.childAfterBlur = d.hasFocus();
    }
    f.remove();

    const a = body.appendChild(document.createElement("iframe"));
    const b = body.appendChild(document.createElement("iframe"));
    const ai = a.contentDocument.body.appendChild(a.contentDocument.createElement('input'));
    const bi = b.contentDocument.body.appendChild(b.contentDocument.createElement('input'));
    ai.focus();
    out.aAfterAFocus = a.contentDocument.hasFocus();
    out.bAfterAFocus = b.contentDocument.hasFocus();
    bi.focus();
    out.aAfterBFocus = a.contentDocument.hasFocus();
    out.bAfterBFocus = b.contentDocument.hasFocus();

    const own = body.appendChild(document.createElement('input'));
    own.focus();
    out.aAfterTopFocus = a.contentDocument.hasFocus();
    out.bAfterTopFocus = b.contentDocument.hasFocus();
    out.topAfterTopFocus = document.hasFocus();
    a.remove();
    b.remove();
    own.remove();
    return out;
})()
