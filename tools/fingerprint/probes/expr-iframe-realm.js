// Does a child frame get its own realm?
//
// The Akamai sensor's `whY` (sensor script offset 172621) creates a
// `display:none` iframe, appends it, and calls `OV(iframe)`, which runs the same
// collector twice: `TEY(iframe.contentWindow)` and `TEY(window)`. One of that
// collector's fields is built by `win.document.createElement('canvas')` ->
// `getContext('webgl')` -> `WEBGL_debug_renderer_info`, so the sensor is
// comparing the child frame's GPU strings against the top frame's.
//
// A probe that wraps the *top* frame's `HTMLCanvasElement.prototype.getContext`
// saw that call once in Chrome and twice in this engine. Both arms make both
// calls; the question is whose prototype the child frame's canvas inherits. If
// the child hands back objects from the parent realm, the top frame's wrapper
// sees them -- and, more to the point, every identity the sensor compares
// across the two windows collapses to "the same object".
(() => {
    const f = document.createElement('iframe');
    f.style.display = 'none';
    document.body.appendChild(f);
    const w = f.contentWindow;
    const out = {
        contentWindow: typeof w,
        isTopWindow: w === self,
        documentReachable: !!(w && w.document),
        documentIsTopDocument: !!w && w.document === document,
    };
    if (w && w.document) {
        const names = ['Object', 'Array', 'Function', 'Window', 'Document',
            'HTMLCanvasElement', 'CanvasRenderingContext2D', 'WebGLRenderingContext',
            'Navigator', 'Error', 'Promise', 'JSON'];
        out.sameInterfaceObject = {};
        for (const n of names) out.sameInterfaceObject[n] = w[n] === self[n];
        const c = w.document.createElement('canvas');
        out.canvas = {
            protoIsParentProto: Object.getPrototypeOf(c) === HTMLCanvasElement.prototype,
            protoIsChildProto: !!w.HTMLCanvasElement && Object.getPrototypeOf(c) === w.HTMLCanvasElement.prototype,
            instanceofParent: c instanceof HTMLCanvasElement,
            ctorIsParentCtor: c.constructor === HTMLCanvasElement,
        };
        out.navigator = {
            sameObject: w.navigator === navigator,
            sameUA: w.navigator && w.navigator.userAgent === navigator.userAgent,
        };
        // The sensor also reads `win.document.documentElement.<x>` and a typeof
        // off the window, so an empty child document shows up there too.
        out.childDoc = {
            hasDocumentElement: !!w.document.documentElement,
            docElTag: w.document.documentElement && w.document.documentElement.tagName,
            url: String(w.location && w.location.href),
            childOfTop: w.parent === self,
        };
    }
    f.remove();
    return out;
})()
