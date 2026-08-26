// What happens to a frame when its <iframe> leaves the document.
//
// The macys interstitial creates hidden iframes and removes them again (the
// collector's own reads include `Element.remove` five times), and on the replay
// this engine answers `window.frames.length === 5` where Chrome answers 2. Per
// HTML §iframe, removing the element destroys the nested navigable; this asks
// both engines every question that follows from that -- the count, the element's
// own accessors, a reference captured before the removal, and what re-inserting
// the same element does.
(() => {
    const out = {};
    const put = (k, f) => { try { out[k] = String(f()); } catch (e) { out[k] = 'throw: ' + (e && e.message); } };
    const mk = (src) => {
        const f = document.createElement('iframe');
        f.style.display = 'none';
        if (src !== undefined) f.src = src;
        document.body.appendChild(f);
        return f;
    };

    put('0.count', () => window.frames.length);
    const a = mk();
    put('1.count', () => window.frames.length);
    const saved = a.contentWindow;
    const savedDoc = a.contentDocument;
    put('1.savedWindowIsWindow', () => Object.prototype.toString.call(saved));
    a.remove();
    put('2.count', () => window.frames.length);
    put('2.window0', () => typeof window[0]);
    put('2.contentWindow', () => a.contentWindow === null ? 'null' : Object.prototype.toString.call(a.contentWindow));
    put('2.contentDocument', () => a.contentDocument === null ? 'null' : Object.prototype.toString.call(a.contentDocument));
    put('2.savedWindowStillWindow', () => Object.prototype.toString.call(saved));
    put('2.savedWindowClosed', () => saved.closed);
    put('2.savedWindowDocument', () => saved.document === null ? 'null' : Object.prototype.toString.call(saved.document));
    put('2.savedWindowParent', () => saved.parent === saved ? 'self' : (saved.parent === window ? 'top-window' : String(saved.parent)));
    put('2.savedDocSameAsNow', () => savedDoc === a.contentDocument);
    put('2.savedWindowLocation', () => saved.location && saved.location.href);

    // Re-insert the very same element: a fresh navigable, or the old one back?
    document.body.appendChild(a);
    put('3.count', () => window.frames.length);
    put('3.contentWindowIsSaved', () => a.contentWindow === saved);
    put('3.contentDocumentIsSaved', () => a.contentDocument === savedDoc);

    // A second element, removed by its parent rather than by itself, and one
    // moved to a detached parent (which is a removal from the document too).
    const b = mk('about:blank');
    put('4.count', () => window.frames.length);
    b.parentNode.removeChild(b);
    put('5.count', () => window.frames.length);
    const holder = document.createElement('div');
    const c = mk();
    put('6.count', () => window.frames.length);
    holder.appendChild(c);
    put('7.countAfterMoveToDetached', () => window.frames.length);
    document.body.appendChild(holder);
    put('8.countAfterHolderAttached', () => window.frames.length);

    // And the whole subtree at once: innerHTML wiping a container that holds one.
    const box = document.createElement('div');
    document.body.appendChild(box);
    const d = document.createElement('iframe');
    d.style.display = 'none';
    box.appendChild(d);
    put('9.count', () => window.frames.length);
    box.innerHTML = '';
    put('10.countAfterInnerHtmlWipe', () => window.frames.length);
    put('11.liveIframesInDocument', () => document.getElementsByTagName('iframe').length);
    return JSON.stringify(out);
})()
