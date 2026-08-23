// What a *setter* says when it refuses the value.
//
// probe-invalid-argument.js walked operations and constructors and found the two
// lead-ins Blink puts in front of the detail sentence -- "Failed to construct
// 'X': " and "Failed to execute 'x' on 'Y': ". A setter is the third:
//
//     Failed to set the '<prop>' property on '<Interface>': <detail>
//
// That probe left one case unfixed because it belongs here: `url.href = 'nope'`
// throws with an *empty* message in this engine. No browser throws an empty
// string, so the assignment is a tell on its own, before any wording question.
//
// The list below is deliberately mixed, because "the setter refuses" is several
// different mechanisms wearing one prefix and only a measurement separates them:
//
//   * the brand check on an interface-typed attribute (document.body = 1)
//   * a DOMException raised by the setter's own steps after the value converted
//     fine (document.body = <div>, input.size = 0, audio.volume = 5)
//   * a parse failure inside the attribute's setter (url.href, location.protocol)
//   * the numeric guards WebIDL puts on double / unrestricted double
//   * an enum-typed attribute, which WebIDL says must *silently ignore* a bad
//     value rather than throw -- included so the silence is on the record and
//     nobody 'fixes' it into a throw later
//   * a strict-mode write to a property with no setter at all, which is V8's
//     sentence and carries no Blink prefix
//   * a setter unbound from its interface, which is the Illegal invocation family
//
// Run against a real http page -- several of these need a document, and
// document.domain reads the origin's host:
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-setter-refusal.js \
//       http://127.0.0.1:9721/ --headed
//
// Readings in results/probes/probe-setter-refusal.{chrome,lightpanda}.json.
(() => {
    const out = {};

    // What the assignment did: the error, or the value that stuck afterwards.
    const set = (label, fn, read) => {
        try {
            fn();
            let after;
            try {
                after = read === undefined ? undefined : String(read());
            } catch (e) {
                after = '<read threw: ' + e + '>';
            }
            out[label] = { throws: false, after: after };
        } catch (e) {
            out[label] = {
                throws: true,
                name: e?.name ?? String(e),
                message: e?.message ?? '',
            };
        }
    };

    const el = (tag) => document.createElement(tag);

    // --- parse failure inside the setter's own steps -----------------------
    const url = new URL('http://x.test/a');
    set("url.href = 'nope'", () => { url.href = 'nope'; }, () => url.href);
    set("url.href = ''", () => { new URL('http://x.test/').href = ''; });
    set("url.protocol = 'no pe'", () => {
        const u = new URL('http://x.test/');
        u.protocol = 'no pe';
        return u;
    }, () => new URL('http://x.test/').protocol);
    set("url.port = 'nope'", () => { new URL('http://x.test/').port = 'nope'; });
    set("url.host = ''", () => { new URL('http://x.test/').host = ''; });
    set("location.protocol = 'nope'", () => { location.protocol = 'nope'; });
    set("location.port = 'nope'", () => { location.port = 'nope'; });

    // --- brand check on an interface-typed attribute -----------------------
    set("document.body = 1", () => { document.body = 1; });
    set("document.body = 'x'", () => { document.body = 'x'; });
    set("document.body = {}", () => { document.body = {}; });
    set("document.body = document.createTextNode('x')", () => {
        document.body = document.createTextNode('x');
    });
    set("table.tHead = 1", () => { el('table').tHead = 1; });
    set("table.tFoot = {}", () => { el('table').tFoot = {}; });
    set("table.caption = 1", () => { el('table').caption = 1; });
    set("video.srcObject = 1", () => { el('video').srcObject = 1; });
    set("audio.srcObject = {}", () => { el('audio').srcObject = {}; });
    // The brand check this engine can actually reach today: its currentNode
    // setter is typed `*Node`, so the conversion runs and refuses.
    set("treeWalker.currentNode = 1", () => {
        document.createTreeWalker(document.body).currentNode = 1;
    });
    set("treeWalker.currentNode = {}", () => {
        document.createTreeWalker(document.body).currentNode = {};
    });
    set("document.adoptedStyleSheets = 1", () => { document.adoptedStyleSheets = 1; });
    set("input.valueAsDate = 1", () => {
        const i = el('input'); i.type = 'date'; i.valueAsDate = 1;
    });
    set("input.valueAsDate = {} (type=date)", () => {
        const i = el('input'); i.type = 'date'; i.valueAsDate = {};
    });

    // --- the setter's own steps throw a DOMException -----------------------
    set("document.body = document.createElement('div')", () => {
        document.body = el('div');
    });
    set("table.tHead = document.createElement('div')", () => {
        el('table').tHead = el('div');
    });
    set("table.caption = document.createElement('div')", () => {
        el('table').caption = el('div');
    });
    set("input.size = 0", () => { el('input').size = 0; }, () => el('input').size);
    set("textarea.cols = 0", () => { el('textarea').cols = 0; });
    set("textarea.rows = 0", () => { el('textarea').rows = 0; });
    set("input.maxLength = -1", () => { el('input').maxLength = -1; });
    set("textarea.maxLength = -1", () => { el('textarea').maxLength = -1; });
    set("select.length = -1", () => { el('select').length = -1; });
    set("audio.volume = 5", () => { el('audio').volume = 5; });
    set("audio.volume = -1", () => { el('audio').volume = -1; });
    set("input.selectionStart = 1 (type=number)", () => {
        const i = el('input'); i.type = 'number'; i.selectionStart = 1;
    });
    set("input.valueAsNumber = 1 (type=text)", () => {
        el('input').valueAsNumber = 1;
    });
    set("input.valueAsDate = new Date() (type=text)", () => {
        el('input').valueAsDate = new Date();
    });
    set("document.domain = 'evil.test'", () => { document.domain = 'evil.test'; });

    // --- WebIDL numeric guards --------------------------------------------
    set("video.currentTime = 'x'", () => { el('video').currentTime = 'x'; });
    set("video.currentTime = NaN", () => { el('video').currentTime = NaN; });
    set("video.currentTime = Infinity", () => { el('video').currentTime = Infinity; });
    set("audio.playbackRate = 'x'", () => { el('audio').playbackRate = 'x'; });
    set("input.valueAsNumber = 'x' (type=number)", () => {
        const i = el('input'); i.type = 'number'; i.valueAsNumber = 'x';
    });
    set("el.scrollTop = 'x'", () => { document.body.scrollTop = 'x'; },
        () => document.body.scrollTop);
    set("canvas.width = 'x'", () => { el('canvas').width = 'x'; },
        () => { const c = el('canvas'); c.width = 'x'; return c.width; });
    set("img.width = -1", () => { const i = el('img'); i.width = -1; return i; },
        () => { const i = el('img'); i.width = -1; return i.width; });

    // --- enum-typed attribute: WebIDL says ignore, never throw -------------
    set("xhr.responseType = 'nope'", () => { new XMLHttpRequest().responseType = 'nope'; },
        () => { const x = new XMLHttpRequest(); x.responseType = 'nope'; return x.responseType; });
    set("history.scrollRestoration = 'nope'", () => { history.scrollRestoration = 'nope'; },
        () => history.scrollRestoration);
    set("img.loading = 'nope'", () => { const i = el('img'); i.loading = 'nope'; },
        () => { const i = el('img'); i.loading = 'nope'; return i.loading; });
    set("img.crossOrigin = 'nope'", () => { const i = el('img'); i.crossOrigin = 'nope'; },
        () => { const i = el('img'); i.crossOrigin = 'nope'; return i.crossOrigin; });
    set("input.type = 'nope'", () => { const i = el('input'); i.type = 'nope'; },
        () => { const i = el('input'); i.type = 'nope'; return i.type; });

    // --- a callback-typed attribute given a non-callable --------------------
    set("el.onclick = 1", () => { const d = el('div'); d.onclick = 1; },
        () => { const d = el('div'); d.onclick = 1; return d.onclick; });
    set("xhr.onload = 'x'", () => { new XMLHttpRequest().onload = 'x'; },
        () => { const x = new XMLHttpRequest(); x.onload = 'x'; return x.onload; });

    // --- no setter at all, in strict mode: V8's sentence, no Blink prefix ---
    set("'use strict' navigator.userAgent = 'x'", () => {
        'use strict';
        navigator.userAgent = 'x';
    });
    set("'use strict' document.URL = 'x'", () => {
        'use strict';
        document.URL = 'x';
    });
    set("'use strict' el.tagName = 'x'", () => {
        'use strict';
        document.body.tagName = 'x';
    });
    set("'use strict' window.origin = 'x'", () => {
        'use strict';
        window.origin = 'x';
    });
    set("sloppy navigator.userAgent = 'x'", () => { navigator.userAgent = 'x'; },
        () => navigator.userAgent.slice(0, 8));

    // --- the setter unbound from its interface ------------------------------
    const hrefSetter = Object.getOwnPropertyDescriptor(URL.prototype, 'href')?.set;
    set("URL href setter .call(document)", () => { hrefSetter.call(document, 'x'); });
    set("URL href setter .call({})", () => { hrefSetter.call({}, 'x'); });
    const bodySetter = Object.getOwnPropertyDescriptor(Document.prototype, 'body')?.set;
    set("Document body setter .call({})", () => { bodySetter.call({}, null); });

    // Last, because an engine that lets this one through has replaced the
    // document the cases above were reading.
    set("documentElement.outerHTML = 'x'", () => {
        document.documentElement.outerHTML = 'x';
    });

    // --- how the setters advertise themselves ------------------------------
    out['descriptors'] = {
        'URL.href set.name': hrefSetter?.name ?? null,
        'URL.href set.length': hrefSetter?.length ?? null,
        'Document.body set.name': bodySetter?.name ?? null,
        'Document.body set.length': bodySetter?.length ?? null,
    };

    return out;
})();
