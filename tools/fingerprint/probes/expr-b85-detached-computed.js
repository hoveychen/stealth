// What `getComputedStyle` answers for an element that is not in a document.
//
// The claim to check is "every property is the empty string in Chrome and this
// engine returns values". Before building on it: is it EVERY property or only
// the ones that need a box; what do the declaration-level members say
// (`length`, `item(0)`, `cssText`); and which kinds of not-in-a-document does
// it cover -- a fresh createElement, a subtree that was removed, an element
// living in a document with no browsing context.
//
// The controls matter as much as the cases. A `display:none` element that IS in
// the document still has a computed style, and so does `visibility:hidden`; if
// the rule were "no box, no style" those would be empty too and they are not.
(() => {
    const out = {};
    const PROPS = ['width', 'height', 'display', 'color', 'font-size', 'font-family',
        'margin-left', 'padding-top', 'border-top-width', 'opacity', 'visibility',
        'position', 'z-index', 'line-height', 'background-color', 'direction',
        'writing-mode', 'transform', 'inset-inline-start', '--custom'];

    const survey = (label, el) => {
        const cs = getComputedStyle(el);
        const values = {};
        for (const p of PROPS) values[p] = cs.getPropertyValue(p);
        out[label] = {
            length: cs.length,
            item0: cs.item(0),
            cssText: String(cs.cssText).slice(0, 40),
            // The named getter beside getPropertyValue: they can disagree.
            widthNamed: cs.width,
            displayNamed: cs.display,
            allEmpty: Object.values(values).every((v) => v === ''),
            nonEmpty: Object.entries(values).filter(([, v]) => v !== '').map(([k, v]) => k + '=' + v),
        };
    };

    // 1. Never in a document.
    survey('fresh_createElement', document.createElement('div'));

    // 2. Built with markup and still never appended.
    const holder = document.createElement('div');
    holder.innerHTML = '<p style="width:50px;color:red">x</p>';
    survey('detached_subtree_child', holder.firstChild);

    // 3. Appended, then removed again.
    const removed = document.createElement('div');
    removed.style.width = '50px';
    document.body.appendChild(removed);
    const whileAttached = getComputedStyle(removed).width;
    removed.remove();
    survey('removed_after_append', removed);
    out.width_while_attached = whileAttached;

    // 4. An element in a document that has no browsing context.
    const doc = document.implementation.createHTMLDocument('d');
    const inOtherDoc = doc.createElement('div');
    doc.body.appendChild(inOtherDoc);
    survey('in_document_without_browsing_context', inOtherDoc);

    // 5..7 The controls: in the document, with and without a box.
    const shown = document.createElement('div');
    shown.style.width = '50px';
    document.body.appendChild(shown);
    survey('attached_rendered', shown);

    const hidden = document.createElement('div');
    hidden.style.cssText = 'width:50px;visibility:hidden';
    document.body.appendChild(hidden);
    survey('attached_visibility_hidden', hidden);

    const none = document.createElement('div');
    none.style.cssText = 'width:50px;display:none';
    document.body.appendChild(none);
    survey('attached_display_none', none);

    shown.remove();
    hidden.remove();
    none.remove();

    // Does a live computed style object follow the element out of the document?
    const live = document.createElement('div');
    live.style.width = '50px';
    document.body.appendChild(live);
    const cs = getComputedStyle(live);
    const before = cs.width;
    live.remove();
    out.live_object_across_removal = { before, after: cs.width, lengthAfter: cs.length };

    return JSON.stringify(out, null, 1);
})()
