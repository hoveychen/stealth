// What `javascript:` URLs does the challenge actually navigate to?
//
// An x-hyatt run leaves two `javascript-url compile` CompilationError lines in
// the engine log, on about:blank frames, and Kasada reads
// HTMLIFrameElement.contentWindow 91 times there. The warning does not carry
// the source, and asking the question from outside -- plant candidate sources
// and see which warn -- turned out to measure the probe rather than the engine:
// the javascript: URL runs as a scheduled task, so its warning lands wherever
// the harness's settle happens to put it, and three probe configurations gave
// three mutually inconsistent answers.
//
// So ask the page instead. Every route a `javascript:` URL can take -- the
// `src` property, setAttribute, an anchor's href, location, window.open -- is
// wrapped to report the source verbatim on the console, which --trace already
// records. Nothing is blocked or altered; the original setter still runs.
(() => {
    // Reported through document.title, not the console. antibot-sweep records
    // the title per station and deliberately never sends Runtime.enable --
    // Kasada withholds clearance from a client that has -- so console output
    // from a station run is not merely unrecorded, it does not exist.
    const seen = [];
    const say = (how, value) => {
        try {
            if (typeof value === 'string' && value.slice(0, 11).toLowerCase() === 'javascript:') {
                seen.push(how + ' ' + JSON.stringify(value));
                if (document && document.title !== undefined) {
                    document.title = 'JSURL[' + seen.length + '] ' + seen.join(' | ').slice(0, 900);
                }
            }
        } catch (e) { /* reporting must never break the page */ }
    };

    const wrapUrlProperty = (proto, name, label) => {
        try {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.set) return;
            Object.defineProperty(proto, name, {
                configurable: true,
                enumerable: d.enumerable,
                get: d.get,
                set(v) { say(label, String(v)); return d.set.call(this, v); },
            });
        } catch (e) { /* an unwrappable accessor is one fewer route, not a failure */ }
    };

    wrapUrlProperty(HTMLIFrameElement.prototype, 'src', 'iframe.src');
    wrapUrlProperty(HTMLFrameElement && HTMLFrameElement.prototype, 'src', 'frame.src');
    wrapUrlProperty(HTMLAnchorElement.prototype, 'href', 'a.href');
    wrapUrlProperty(HTMLEmbedElement.prototype, 'src', 'embed.src');
    wrapUrlProperty(HTMLObjectElement.prototype, 'data', 'object.data');

    const setAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
        const n = String(name).toLowerCase();
        if (n === 'src' || n === 'href' || n === 'data' || n === 'action') say('setAttribute:' + n, String(value));
        return setAttribute.call(this, name, value);
    };

    const open = window.open;
    window.open = function (url, ...rest) { say('window.open', String(url)); return open.call(this, url, ...rest); };

    for (const name of ['assign', 'replace']) {
        try {
            const fn = Location.prototype[name];
            Location.prototype[name] = function (url) { say('location.' + name, String(url)); return fn.call(this, url); };
        } catch (e) { /* same as above */ }
    }
    wrapUrlProperty(Location.prototype, 'href', 'location.href');

    // The routes above are all property writes. Markup is not: an iframe parsed
    // out of innerHTML or document.write carries its src without any setter
    // running, and the log line says these frames are about:blank, which is
    // what an iframe with no src *or* a javascript: src reports. So watch the
    // tree as well and report any src/href attribute that arrives that way.
    try {
        const report = (node) => {
            if (!node || node.nodeType !== 1) return;
            for (const attr of ['src', 'href', 'data', 'action']) {
                const v = node.getAttribute && node.getAttribute(attr);
                if (v) say('markup:' + node.tagName.toLowerCase() + '.' + attr, v);
            }
            if (node.querySelectorAll) for (const kid of node.querySelectorAll('*')) report(kid);
        };
        new MutationObserver((records) => {
            for (const r of records) {
                for (const n of r.addedNodes) report(n);
                if (r.type === 'attributes') report(r.target);
            }
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'href', 'data', 'action'] });
    } catch (e) { /* an engine without MutationObserver loses this route only */ }
})();
