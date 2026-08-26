// `iframe.contentDocument` decides the child document's realm, permanently.
//
// A child frame's `document` getter lives on the *child's* global, so reading
// `iframe.contentWindow.document` enters the child's v8 context and the wrapper
// is born in the child's realm -- correct. `iframe.contentDocument` is an
// accessor on the *parent's* `HTMLIFrameElement.prototype`
// (src/browser/webapi/element/html/IFrame.zig:50-58), so reading it runs in the
// parent's context, and `Local.mapZigInstanceToJs` builds the wrapper with
// whatever context is entered (src/browser/js/Local.zig:325-332). The result is
// cached in an `identity_map` keyed by the raw Zig pointer with no realm in the
// key (Local.zig:305-313, Identity.zig:37), shared by every frame of the Page
// (Page.zig:92-94) -- so whichever realm asks first owns the wrapper for the
// life of the page.
//
// Reading `contentDocument` first therefore hands the child's own document the
// *parent's* prototypes, and every element it creates follows, because
// `createElement` is then resolved off the parent's `Document.prototype` and
// calling it enters the parent's context. The child frame's own script sees it
// too: `Object.getPrototypeOf(document) === HTMLDocument.prototype` reads false
// inside the frame.
//
// Two frames, identical but for the order of the first read. Chrome answers
// `false` to every `IsTop` below in both frames.
(() => {
    const mk = () => {
        const f = document.createElement('iframe');
        f.style.display = 'none';
        document.body.appendChild(f);
        return f;
    };
    const out = {};

    // A -- `contentDocument` first, the way the Akamai loader reads it.
    const a = mk();
    out.aFirstRead = 'contentDocument';
    const aDoc = a.contentDocument;
    const aWin = a.contentWindow;
    out.aDocProtoIsTop = Object.getPrototypeOf(aDoc) === Object.getPrototypeOf(document);
    out.aWindowDocSameObject = aWin.document === aDoc;
    out.aWindowDocProtoIsTop = Object.getPrototypeOf(aWin.document) === Object.getPrototypeOf(document);
    out.aCanvasProtoIsTop =
        Object.getPrototypeOf(aWin.document.createElement('canvas')) === HTMLCanvasElement.prototype;
    out.aInsideSaysOwnProto = aWin.eval('Object.getPrototypeOf(document) === HTMLDocument.prototype');
    out.aInsideSaysOwnCanvas = aWin.eval(
        "Object.getPrototypeOf(document.createElement('canvas')) === HTMLCanvasElement.prototype");

    // B -- `contentWindow.document` first, everything else identical.
    const b = mk();
    out.bFirstRead = 'contentWindow.document';
    const bWin = b.contentWindow;
    const bDocViaWindow = bWin.document;
    out.bDocProtoIsTop = Object.getPrototypeOf(bDocViaWindow) === Object.getPrototypeOf(document);
    out.bContentDocumentSameObject = b.contentDocument === bDocViaWindow;
    out.bContentDocumentProtoIsTop = Object.getPrototypeOf(b.contentDocument) === Object.getPrototypeOf(document);
    out.bCanvasProtoIsTop =
        Object.getPrototypeOf(bWin.document.createElement('canvas')) === HTMLCanvasElement.prototype;
    out.bInsideSaysOwnProto = bWin.eval('Object.getPrototypeOf(document) === HTMLDocument.prototype');
    out.bInsideSaysOwnCanvas = bWin.eval(
        "Object.getPrototypeOf(document.createElement('canvas')) === HTMLCanvasElement.prototype");

    a.remove();
    b.remove();
    return out;
})()
