// Where `activeElement` points while the focus is inside a child frame.
//
// expr-b85-has-focus.js left one reading unmatched: after focusing an input in
// a same-origin child, Chrome's TOP document reports `activeElement` as the
// IFRAME element and this engine reports BODY. One reading is not enough to
// build on -- what the parent says after the child's element is blurred, and
// what both say once focus moves back to top-level content, decide whether the
// rule is "the host iframe while a descendant has focus" or something narrower.
(async () => {
    const out = {};
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const tag = (el) => (el ? (el.id ? el.tagName + '#' + el.id : el.tagName) : String(el));

    const own = document.createElement('input');
    own.id = 'own';
    document.body.appendChild(own);

    const f = document.createElement('iframe');
    f.id = 'host';
    f.srcdoc = '<!doctype html><body><input id=i><input id=j></body>';
    document.body.appendChild(f);
    await new Promise((r) => { f.onload = r; setTimeout(r, 2000); });
    await wait(200);
    const doc = f.contentDocument;

    const snap = (label) => {
        out[label] = {
            topActive: tag(document.activeElement),
            childActive: tag(doc.activeElement),
            topFocus: document.hasFocus(),
            childFocus: doc.hasFocus(),
        };
    };

    snap('initial');

    doc.getElementById('i').focus();
    await wait(150);
    snap('after_child_input_focus');

    doc.getElementById('j').focus();
    await wait(150);
    snap('after_child_second_input');

    doc.getElementById('j').blur();
    await wait(150);
    snap('after_child_blur');

    own.focus();
    await wait(150);
    snap('after_top_input_focus');

    own.blur();
    await wait(150);
    snap('after_top_blur');

    f.remove();
    own.remove();
    return JSON.stringify(out, null, 1);
})()
