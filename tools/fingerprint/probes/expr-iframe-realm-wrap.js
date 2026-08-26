// Does patching the top frame's prototype change what a child frame's element
// does? It must not: each frame is its own realm with its own prototypes, so a
// wrapper installed up here can never see a call made on an element the child
// document created.
//
// On the live Akamai interstitial it does. `probe-canvas-order.js` wraps only
// the top frame's `HTMLCanvasElement.prototype.getContext`, and in this engine
// it recorded a call on a canvas whose `ownerDocument` is the sensor's hidden
// iframe -- Chrome recorded nothing there. This checks the same thing in
// isolation, and reports both halves: whether the identities look separate, and
// whether the behaviour actually is.
// The sensor's iframe carries `src="https://"` -- a URL that cannot be
// navigated to -- so the src is part of the case, not decoration.
(() => {
    // Order matters as much as the value: the sensor appends first, reads
    // `contentWindow` once, *then* assigns the src, and only then reads
    // `contentWindow` again for the collector under study. A src assigned after
    // the frame is live is a navigation, and a navigation is where a fresh
    // document can appear without a fresh realm behind it.
    const srcArg = self.__iframeSrc;
    const f = document.createElement('iframe');
    f.style.display = 'none';
    document.body.appendChild(f);
    void f.contentWindow;
    if (srcArg !== undefined) f.src = srcArg;
    const w = f.contentWindow;

    let firedOnTopWrapper = 0;
    const original = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function () {
        firedOnTopWrapper++;
        return original.apply(this, arguments);
    };

    const childCanvas = w.document.createElement('canvas');
    const childCtx = childCanvas.getContext('2d');
    const firedForChild = firedOnTopWrapper;
    const topCanvas = document.createElement('canvas');
    topCanvas.getContext('2d');
    const firedForTop = firedOnTopWrapper - firedForChild;

    HTMLCanvasElement.prototype.getContext = original;

    const out = {
        // Behaviour: the number that matters.
        topWrapperSawChildCall: firedForChild,
        topWrapperSawTopCall: firedForTop,
        // Identities, for comparison with the behaviour above.
        childCtorIsTopCtor: w.HTMLCanvasElement === HTMLCanvasElement,
        childProtoIsTopProto: w.HTMLCanvasElement.prototype === HTMLCanvasElement.prototype,
        childCanvasProtoIsTopProto: Object.getPrototypeOf(childCanvas) === HTMLCanvasElement.prototype,
        childCanvasProtoIsChildProto: Object.getPrototypeOf(childCanvas) === w.HTMLCanvasElement.prototype,
        childGetContextIsTopGetContext: childCanvas.getContext === original,
        childCtxProtoIsTopProto: Object.getPrototypeOf(childCtx) === CanvasRenderingContext2D.prototype,
        childOwnerIsChildDoc: childCanvas.ownerDocument === w.document,
    };
    f.remove();
    return out;
})()
