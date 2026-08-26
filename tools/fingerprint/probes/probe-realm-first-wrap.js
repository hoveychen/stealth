// Who wraps a child frame's document first, and does that decide its realm?
//
// `probe-canvas-order.js` measured that a control iframe's `contentWindow`
// hands back parent-realm objects, but only from some point in the page's life
// onward: correct at inject and at t100, leaking from t300. A pristine page
// could not reproduce it in a dozen shapes, so the trigger looked mysterious.
//
// Reading the engine explains the shape. `Local.mapZigInstanceToJs`
// (src/browser/js/Local.zig:290-332) creates a wrapper by calling
// `ObjectTemplate::NewInstance(self.handle)`, where `self.handle` is *the
// currently entered v8 context* -- and it caches the result in an
// `identity_map` keyed by the raw Zig pointer alone, with no realm in the key
// (Local.zig:305-313, Identity.zig:37), shared by every frame of the Page
// (Page.zig:92-94). So the first realm to ask for a given Zig object owns its
// wrapper for the life of the page.
//
// That predicts an *order-dependent* answer, which is exactly the symptom:
//   - if the child realm touches its own `document` first, the wrapper is a
//     child-realm object, `contentWindow.document.createElement` resolves off
//     the child's `Document.prototype`, calling it enters the child context,
//     and the element comes out with child prototypes. Correct.
//   - if the top realm reads `contentWindow.document` first, the wrapper is a
//     top-realm object and every call through it cascades into the top realm.
//     Leaking.
//
// This probe tests that prediction. At each sample point it makes two identical
// frames and treats them differently: frame A is read straight from the top
// frame; frame B is asked to touch its own `document` from inside its own realm
// first. If the mechanism is right, A leaks wherever the earlier probe leaked
// and B never does -- and the same page state that leaks A becomes harmless the
// moment the child goes first.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var out = (probe.realm = probe.realm || []);

    function mk() {
        var f = self.document.createElement('iframe');
        f.style.display = 'none';
        self.document.body.appendChild(f);
        return f;
    }

    function protoName(o) {
        try {
            var p = Object.getPrototypeOf(o);
            if (p === null) return 'null';
            return (p.constructor && p.constructor.name) || 'anonymous';
        } catch (e) {
            return 'threw';
        }
    }

    // Every child document this probe has seen, so a later sample can say "this
    // is the object an earlier frame handed me" rather than only "it is not
    // mine". A recycled Zig address plus an `identity_map` that is never purged
    // when a frame dies would show up here and nowhere else.
    var seen = [];

    function sample(tag) {
        var r = { at: tag };
        var fA = null;
        var fB = null;
        try {
            // A -- the top frame asks first.
            fA = mk();
            var wA = fA.contentWindow;
            r.a_docProtoIsTop = Object.getPrototypeOf(wA.document) === Object.getPrototypeOf(self.document);
            r.a_docProto = protoName(wA.document);
            r.a_documentCtorIsTop = wA.Document === self.Document;
            r.a_docConstructorIsTop = wA.document.constructor === self.document.constructor;
            r.a_docIsTopDocument = wA.document === self.document;
            r.a_docBodyIsTopBody = wA.document.body === self.document.body;
            try {
                r.a_docUrl = String(wA.document.URL);
                r.a_docChildCount = wA.document.documentElement ? wA.document.documentElement.childNodes.length : -1;
            } catch (e) {
                r.a_docReadErr = String(e);
            }
            r.a_docSeenBefore = seen.indexOf(wA.document);
            seen.push(wA.document);
            var cA = wA.document.createElement('canvas');
            r.a_canvasProtoIsTop = Object.getPrototypeOf(cA) === self.HTMLCanvasElement.prototype;

            // B -- the child realm touches its own document first.
            fB = mk();
            var wB = fB.contentWindow;
            try {
                wB.eval('void document');
                r.b_pretouch = 'eval';
            } catch (e) {
                r.b_pretouchErr = String(e);
            }
            // Is the child's own `eval` even running in the child's realm? If an
            // object literal it evaluates comes back wearing the top frame's
            // `Object.prototype`, the child realm has collapsed into the top one
            // and "who wrapped the document first" was never the question.
            try {
                var lit = wB.eval('({})');
                r.b_evalLiteralProtoIsTop = Object.getPrototypeOf(lit) === Object.prototype;
                r.b_evalLiteralProtoIsChild = Object.getPrototypeOf(lit) === wB.Object.prototype;
                var fnLit = wB.eval('(function(){})');
                r.b_evalFnProtoIsTop = Object.getPrototypeOf(fnLit) === Function.prototype;
            } catch (e) {
                r.b_evalLiteralErr = String(e);
            }
            // C -- read the child's document from *inside* the child realm, and
            // never touch it from the top frame at all. If it still wears the
            // top frame's prototype the wrapper was made in the top realm
            // before any script asked for it, which points at frame setup
            // running while the parent's context was entered -- not at the
            // accessor the top frame called.
            var fC = mk();
            var wC = fC.contentWindow;
            try {
                var innerDoc = wC.eval('document');
                r.c_docProtoIsTop = Object.getPrototypeOf(innerDoc) === Object.getPrototypeOf(self.document);
                r.c_docProtoIsChild = Object.getPrototypeOf(innerDoc) === wC.HTMLDocument.prototype;
                var innerCanvas = wC.eval("document.createElement('canvas')");
                r.c_canvasProtoIsTop = Object.getPrototypeOf(innerCanvas) === self.HTMLCanvasElement.prototype;
                r.c_innerSaysProtoIsOwn = wC.eval('Object.getPrototypeOf(document) === HTMLDocument.prototype');
                r.c_innerSaysCanvasIsOwn = wC.eval(
                    "Object.getPrototypeOf(document.createElement('canvas')) === HTMLCanvasElement.prototype");
            } catch (e) {
                r.c_err = String(e);
            }
            try { fC.remove(); } catch (e) { /* ignore */ }

            r.b_ObjectSameAsTop = wB.Object === self.Object;
            r.b_ArraySameAsTop = wB.Array === self.Array;
            r.b_windowIsTop = wB === self;
            try {
                r.b_navigatorProtoIsTop = Object.getPrototypeOf(wB.navigator) === Object.getPrototypeOf(self.navigator);
                r.b_locationProtoIsTop = Object.getPrototypeOf(wB.location) === Object.getPrototypeOf(self.location);
                r.b_windowProtoIsTop = Object.getPrototypeOf(wB) === Object.getPrototypeOf(self);
            } catch (e) {
                r.b_globalsErr = String(e);
            }
            r.b_docProtoIsTop = Object.getPrototypeOf(wB.document) === Object.getPrototypeOf(self.document);
            r.b_docProto = protoName(wB.document);
            r.b_docConstructorIsTop = wB.document.constructor === self.document.constructor;
            var cB = wB.document.createElement('canvas');
            r.b_canvasProtoIsTop = Object.getPrototypeOf(cB) === self.HTMLCanvasElement.prototype;
        } catch (e) {
            r.err = String(e);
        }
        try {
            if (fA) fA.remove();
            if (fB) fB.remove();
        } catch (e) { /* ignore */ }
        out.push(r);
    }

    sample('inject');
    [50, 100, 200, 300, 600, 1200, 2400].forEach(function (ms) {
        setTimeout(function () {
            sample('t' + ms);
        }, ms);
    });
})();
