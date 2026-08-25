// Which branch of the Akamai loader's tamper check do we take?
//
// The loader (macys `/public/<hash>`, offset 50859) builds a hidden iframe,
// keeps its `contentWindow` in `Ea`, snapshots `Object.toString` -- which is
// `Function.prototype.toString`, inherited by the `Object` constructor -- and
// then, 1400 bytes later:
//
//     let {fetch:Yc, eval:re} = window;
//     !Ea || Yc && Gb(Yc) && Gb(re) || (Yc = Ea.fetch, re = Ea.eval);
//
// with
//
//     Gb = a => { a = Function.prototype.toString.call(a);
//                 a = a.split("[");
//                 return !(!a || !a[1] || "e c" !== a[1][5]+a[1][6]+a[1][7]) }
//
// `"function fetch() { [native code] }".split("[")[1]` is `"native code] }"`,
// whose characters 5,6,7 are `"e c"`. So `Gb` asks "is this still a native
// function", and a `false` from either one makes the loader drop the top
// frame's `fetch`/`eval` and use the hidden child frame's instead for the whole
// rest of the run. Chrome answers true/true and keeps the top frame's.
//
// Two questions, then, and this probe answers both in one reading:
//   1. do we answer `Gb` the same way Chrome does, i.e. do the two arms even
//      take the same branch;
//   2. if the child frame's `eval` gets used, whose realm do the objects it
//      makes belong to -- because a cross-realm `eval` that evaluates in the
//      *top* realm is exactly the shape of the `=TOP` prototype leak the canvas
//      probe measured.
(() => {
    const fnToString = Object.toString;
    const src = (f) => {
        try {
            return fnToString.call(f);
        } catch (e) {
            return 'THREW: ' + e;
        }
    };
    const Gb = (f) => {
        let a = src(f);
        a = a.split('[');
        return !(!a || !a[1] || 'e c' !== a[1][5] + a[1][6] + a[1][7]);
    };
    const protoName = (o) => {
        try {
            const p = Object.getPrototypeOf(o);
            if (p === null) return 'null';
            return (p.constructor && p.constructor.name) || 'anonymous';
        } catch (e) {
            return 'THREW: ' + e;
        }
    };

    const out = {
        objectToStringIsFunctionProtoToString: Object.toString === Function.prototype.toString,
        topFetchSrc: src(window.fetch),
        topEvalSrc: src(window.eval),
        gbTopFetch: Gb(window.fetch),
        gbTopEval: Gb(window.eval),
    };

    // The hidden iframe, made exactly the way the loader makes it.
    let Ea = null;
    try {
        const Ra = document.createElement('iframe');
        Ra.style.width = '0';
        Ra.style.height = '0';
        Ra.style.display = 'none';
        (document.body || document.documentElement).appendChild(Ra);
        Ea = Ra.contentWindow;
    } catch (e) {
        out.iframeThrew = String(e);
    }
    out.eaTruthy = !!Ea;

    if (Ea) {
        try {
            out.eaFetchSrc = src(Ea.fetch);
            out.eaEvalSrc = src(Ea.eval);
            out.gbEaFetch = Gb(Ea.fetch);
            out.gbEaEval = Gb(Ea.eval);
            out.eaFetchSameObjectAsTop = Ea.fetch === window.fetch;
            out.eaEvalSameObjectAsTop = Ea.eval === window.eval;
        } catch (e) {
            out.eaFunctionsThrew = String(e);
        }
    }

    // The branch, written the way the loader writes it.
    out.branch =
        !Ea || (window.fetch && Gb(window.fetch) && Gb(window.eval))
            ? 'keeps the top frame'
            : 'switches to the child frame';

    // What the child frame's `eval` produces, if the loader would reach for it.
    if (Ea) {
        try {
            const o = Ea.eval('({})');
            out.eaEvalObjectProto = protoName(o);
            out.eaEvalObjectProtoIsTop = Object.getPrototypeOf(o) === Object.prototype;
            out.eaEvalObjectProtoIsChild = Object.getPrototypeOf(o) === Ea.Object.prototype;
        } catch (e) {
            out.eaEvalThrew = String(e);
        }
        try {
            const f = Ea.eval('(function(){return 1})');
            out.eaEvalFunctionProtoIsTop = Object.getPrototypeOf(f) === Function.prototype;
            out.eaEvalFunctionProtoIsChild = Object.getPrototypeOf(f) === Ea.Function.prototype;
        } catch (e) {
            out.eaEvalFunctionThrew = String(e);
        }
        // The same reading the canvas probe took, for cross-checking against it.
        try {
            const d = Ea.document;
            out.eaDocumentProto = protoName(d);
            out.eaDocumentProtoIsTop =
                Object.getPrototypeOf(d) === Document.prototype ||
                Object.getPrototypeOf(d) === HTMLDocument.prototype;
            const c = d.createElement('canvas');
            out.eaCanvasProto = protoName(c);
            out.eaCanvasProtoIsTop = Object.getPrototypeOf(c) === HTMLCanvasElement.prototype;
            out.eaCanvasProtoIsChild = Object.getPrototypeOf(c) === Ea.HTMLCanvasElement.prototype;
        } catch (e) {
            out.eaDocumentThrew = String(e);
        }
        // Is the child's own `Object` a distinct binding at all?
        try {
            out.eaObjectSameAsTop = Ea.Object === Object;
            out.eaHTMLCanvasElementSameAsTop = Ea.HTMLCanvasElement === HTMLCanvasElement;
        } catch (e) {
            out.eaIntrinsicsThrew = String(e);
        }
    }

    return out;
})()
