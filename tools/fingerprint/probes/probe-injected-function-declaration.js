// Does a function *declaration* in injected script text become a property of
// window? Turnstile's widget document installs `bGgjP8` that way -- the reach
// probe caught it handing
//   function bGgjP8(s){return function(k){for(var o=new Uint8Array(k.length)...
// to its trusted-types createScript wrapper -- and Chrome's widget realm ends
// up with `bGgjP8` on window while this engine's does not. The VM then reads
// window["bGgjP8"], gets undefined, and `.call` on it is the TypeError two
// sessions have been chasing.
//
// A declaration is not an assignment: it goes in through
// CreateGlobalFunctionBinding, i.e. [[DefineOwnProperty]] on the global object,
// which is exactly why the prototype-chain `set` trap in exception-frames.mjs
// saw nothing and the previous session concluded nobody installed it.
//
// Five ways the same declaration can arrive, so a failure names its mechanism
// rather than just "somewhere in there". Each uses its own name, because a
// later mechanism succeeding would otherwise mask an earlier one's failure.
(async () => {
    const out = { trustedTypes: typeof trustedTypes };

    const check = (name) => {
        // `name in window` and a direct global read can disagree if a binding
        // exists without a matching own property, so record both.
        let viaWindow = 'throw';
        let viaGlobal = 'throw';
        try { viaWindow = typeof window[name]; } catch (e) { viaWindow = 'throw: ' + e.message; }
        try { viaGlobal = (0, eval)(`typeof ${name}`); } catch (e) { viaGlobal = 'throw: ' + e.message; }
        let own = 'throw';
        try { own = Object.getOwnPropertyDescriptor(window, name) ? 'own' : 'not own'; } catch (e) { own = 'throw'; }
        return { viaWindow, viaGlobal, own };
    };

    const run = (label, name, fn) => {
        try {
            fn();
            out[label] = check(name);
        } catch (e) {
            out[label] = { error: String(e && e.message || e) };
        }
    };

    // Expected to stay local in both engines -- this probe body is a function,
    // so a direct eval's declaration belongs to *its* variable environment, not
    // the global one. Kept as the control: if it reads the same in both, the
    // harness is measuring what it thinks it is.
    run('directEval', 'fnDirectEval', () => {
        eval('function fnDirectEval(s){return s}');
    });

    run('indirectEval', 'fnIndirectEval', () => {
        (0, eval)('function fnIndirectEval(s){return s}');
    });

    run('scriptElementText', 'fnScriptText', () => {
        const s = document.createElement('script');
        s.text = 'function fnScriptText(s){return s}';
        document.head.appendChild(s);
    });

    run('scriptElementAppendChildTextNode', 'fnScriptNode', () => {
        const s = document.createElement('script');
        s.appendChild(document.createTextNode('function fnScriptNode(s){return s}'));
        document.head.appendChild(s);
    });

    // The shape the widget actually uses when trusted types are available: the
    // source goes through a policy's createScript before it is assigned.
    run('trustedTypesScriptText', 'fnTrusted', () => {
        let src = 'function fnTrusted(s){return s}';
        if (typeof trustedTypes !== 'undefined' && trustedTypes.createPolicy) {
            const p = trustedTypes.createPolicy('probe-tt', { createScript: (x) => x });
            src = p.createScript(src);
        }
        const s = document.createElement('script');
        s.text = src;
        document.head.appendChild(s);
    });

    // The one the widget actually takes, and the one the other five miss.
    // Under `require-trusted-types-for 'script'` a bare string is refused by
    // eval, so the source arrives as the TrustedScript that createScript
    // returned. V8 on its own returns a non-string argument from eval
    // *unchanged and unexecuted*; only an embedder that unwraps TrustedScript
    // first makes this run. Silent either way -- no throw, no global.
    run('indirectEvalTrustedScript', 'fnEvalTrusted', () => {
        let src = 'function fnEvalTrusted(s){return s}';
        if (typeof trustedTypes !== 'undefined' && trustedTypes.createPolicy) {
            const p = trustedTypes.createPolicy('probe-tt-eval', { createScript: (x) => x });
            src = p.createScript(src);
        }
        (0, eval)(src);
    });

    // Same call with the wrapper stringified by hand, which is what a page
    // would have to do if the engine did not unwrap it. Separates "eval cannot
    // take a TrustedScript" from "the source itself is the problem".
    run('indirectEvalTrustedScriptToString', 'fnEvalTrustedStr', () => {
        let src = 'function fnEvalTrustedStr(s){return s}';
        if (typeof trustedTypes !== 'undefined' && trustedTypes.createPolicy) {
            const p = trustedTypes.createPolicy('probe-tt-eval-str', { createScript: (x) => x });
            src = String(p.createScript(src));
        }
        (0, eval)(src);
    });

    // A blob-URL script, because the widget also hands a blob: URL to its
    // createScriptURL wrapper. Async, so it is awaited rather than checked
    // inline.
    try {
        const url = URL.createObjectURL(new Blob(['function fnBlob(s){return s}'], { type: 'text/javascript' }));
        await new Promise((resolve) => {
            const s = document.createElement('script');
            s.onload = resolve;
            s.onerror = resolve;
            s.src = url;
            document.head.appendChild(s);
            setTimeout(resolve, 2000);
        });
        out.blobUrlScript = check('fnBlob');
    } catch (e) {
        out.blobUrlScript = { error: String(e && e.message || e) };
    }

    return out;
})()
