// What `document.hasFocus()` answers, per frame.
//
// cf-knobs' report-widget-box found it false in Chrome's cross-origin widget
// frame and true here. That is one data point, and a fix built on one data
// point would get the same-origin and the focused-element cases wrong. This
// asks all of them in one page: the top document, a same-origin child that was
// never touched, the same child after focusing an input inside it, and the top
// document again afterwards.
(async () => {
    const out = {};
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));

    out.top_initial = document.hasFocus();

    const f = document.createElement('iframe');
    f.style.cssText = 'width:200px;height:80px';
    f.srcdoc = '<!doctype html><body><input id=i></body>';
    document.body.appendChild(f);
    await new Promise((r) => { f.onload = r; setTimeout(r, 2000); });
    await wait(200);

    const doc = f.contentDocument;
    out.child_srcdoc_initial = doc ? doc.hasFocus() : '(no contentDocument)';
    out.top_after_child_exists = document.hasFocus();

    if (doc) {
        doc.getElementById('i').focus();
        await wait(200);
        out.child_after_focus_input = doc.hasFocus();
        out.top_after_child_focused = document.hasFocus();
        out.top_activeElement = document.activeElement && document.activeElement.tagName;
        out.child_activeElement = doc.activeElement && doc.activeElement.tagName;
        doc.getElementById('i').blur();
        await wait(200);
        out.child_after_blur = doc.hasFocus();
    }

    // A detached document has never been focused and never can be.
    const detached = document.implementation.createHTMLDocument('d');
    out.detached = detached.hasFocus();

    f.remove();
    return JSON.stringify(out, null, 1);
})()
