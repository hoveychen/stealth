// What exactly does `eval` do with a non-string argument, per engine?
//
// probe-injected-function-declaration.js established the divergence: an
// indirect eval handed a TrustedScript runs in Chrome and is a silent no-op
// here. This probe pins down the *shape* of Chrome's behaviour so the fix can
// be written against measurements rather than against a guess about what
// Blink's V8Initializer callback does:
//
//   - direct eval as well as indirect?
//   - `new Function` too?
//   - what comes back as the completion value?
//   - and, the part a fix can easily get wrong, do *other* non-string objects
//     stay unexecuted? A callback that stringifies everything would turn
//     `eval({toString(){...}})` into code execution, which no engine does.
(() => {
    const out = { trustedTypes: typeof trustedTypes };

    const run = (label, fn) => {
        try { out[label] = fn(); } catch (e) { out[label] = 'throw: ' + (e && e.message || e); }
    };

    const policy = (typeof trustedTypes !== 'undefined' && trustedTypes.createPolicy)
        ? trustedTypes.createPolicy('probe-eval-tt', { createScript: (x) => x })
        : null;
    const wrap = (s) => (policy ? policy.createScript(s) : s);

    out.wrapperType = policy ? Object.prototype.toString.call(wrap('1')) : 'no policy';

    // completion value of an expression
    run('indirectExpr', () => (0, eval)(wrap('6 * 7')));
    run('directExpr', () => eval(wrap('6 * 8')));

    // a var statement reaching the global object
    run('indirectVar', () => {
        (0, eval)(wrap('var ttProbeVar = "set";'));
        return typeof window.ttProbeVar + ':' + window.ttProbeVar;
    });

    // the shape Turnstile's widget uses: a function declaration
    run('indirectDecl', () => {
        (0, eval)(wrap('function ttProbeDecl(n){return n+1}'));
        return typeof window.ttProbeDecl + ':' + (typeof window.ttProbeDecl === 'function' ? window.ttProbeDecl(1) : '');
    });

    // a direct eval's declaration belongs to the caller's variable environment,
    // and this probe body is a function, so the global should stay untouched
    // even when the unwrapping works.
    run('directDecl', () => {
        eval(wrap('function ttProbeDirectDecl(n){return n+2}'));
        return 'local:' + typeof ttProbeDirectDecl + ' global:' + typeof window.ttProbeDirectDecl;
    });

    // the Function constructor goes through the same V8 entry point
    run('functionCtorBody', () => new Function(wrap('return 9'))());
    run('functionCtorArgAndBody', () => new Function(wrap('a'), wrap('return a*2'))(21));

    // ---- things that must stay unexecuted ----

    // a plain object with a toString: V8 returns a non-string source unchanged
    run('plainObjectWithToString', () => {
        const o = { toString: () => 'globalThis.ttProbeLeak = 1; 5' };
        const r = (0, eval)(o);
        return (r === o ? 'same object' : 'other: ' + String(r)) + ' leak:' + typeof window.ttProbeLeak;
    });
    run('numberSource', () => {
        const r = (0, eval)(1 + 1);
        return typeof r + ':' + String(r);
    });
    // a TrustedHTML is not a TrustedScript, so it must not be unwrapped
    run('trustedHtmlSource', () => {
        if (!policy) return 'no policy';
        const p2 = trustedTypes.createPolicy('probe-eval-tt-html', { createHTML: (x) => x });
        const h = p2.createHTML('globalThis.ttProbeHtmlLeak = 1; 5');
        const r = (0, eval)(h);
        return (r === h ? 'same object' : 'other: ' + String(r)) + ' leak:' + typeof window.ttProbeHtmlLeak;
    });
    // a string that merely *looks* like the wrapper still goes through the
    // ordinary string path
    run('plainString', () => (0, eval)('6 * 9'));

    return out;
})()
