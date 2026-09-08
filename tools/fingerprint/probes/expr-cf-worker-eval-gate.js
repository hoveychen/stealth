// Cloudflare's guard builds a Blob worker and gates `eval` inside it on three
// MessageEvent invariants. Transcribed verbatim from the disassembled bytecode
// at pc 462141-462575 of the /fo/ program:
//
//   var _p=null;
//   if(self.trustedTypes) try {
//     _p = self.trustedTypes.createPolicy('<name>', {createScript:function(s){return s;}})
//   } catch(e) { self.postMessage({type:'tt-policy-error', msg:e.message}) }
//   onmessage = function(e){
//     e.isTrusted && ''===e.origin && null===e.source && eval(_p ? _p.createScript(e.data) : e.data)
//   }
//
// If any one of isTrusted / origin === '' / source === null is wrong, the eval
// never runs and everything the worker was meant to contribute is silently
// missing from the payload -- a failure no name or value census can see,
// because every name is present and only the gate is wrong.
//
// Arm A runs the guard's source verbatim and asks the only question that
// matters: did the eval run? Arm B is the same worker with instrumentation, to
// say why. No setTimeout anywhere: timers do not fire inside an awaited
// Runtime.evaluate on this engine, so fetch is the pump.
(() => {
    const POLICY = 'FHMZS9';
    const GUARD_SRC =
        "var _p=null;if(self.trustedTypes)try{_p=self.trustedTypes.createPolicy('" + POLICY +
        "',{createScript:function(s){return s;}})}catch(e){self.postMessage({type:'tt-policy-error',msg:e.message})}" +
        "onmessage=function(e){e.isTrusted&&''===e.origin&&null===e.source&&eval(_p?_p.createScript(e.data):e.data)}";
    // Same construction, but it always reports what it saw.
    const PROBE_SRC =
        "var _p=null,_err=null;" +
        "if(self.trustedTypes){try{_p=self.trustedTypes.createPolicy('" + POLICY + "b" +
        "',{createScript:function(s){return s;}})}catch(e){_err=String(e&&e.message)}}" +
        "onmessage=function(e){self.postMessage({tag:'probe'," +
        "hasTT: typeof self.trustedTypes, policyOk: !!_p, policyErr: _err," +
        "isTrusted: e.isTrusted, origin: e.origin, originType: typeof e.origin," +
        "source: e.source === null ? 'null' : String(e.source)," +
        "lastEventId: e.lastEventId, gate: !!(e.isTrusted && ''===e.origin && null===e.source)," +
        "evalType: typeof eval, data: String(e.data)})};";

    const out = {};
    const mk = (src) => {
        const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        return { w: new Worker(url), url };
    };

    let a, b;
    try { a = mk(GUARD_SRC); } catch (e) { out.guardWorker = 'throw:' + e.message; }
    try { b = mk(PROBE_SRC); } catch (e) { out.probeWorker = 'throw:' + e.message; }
    if (!a || !b) return Promise.resolve(out);

    const seen = [];
    a.w.onmessage = (e) => { seen.push(['A', e.data]); };
    b.w.onmessage = (e) => { seen.push(['B', e.data]); };
    a.w.onerror = (e) => { seen.push(['A-error', String(e && (e.message || e.type))]); };
    b.w.onerror = (e) => { seen.push(['B-error', String(e && (e.message || e.type))]); };

    // If the gate passes, arm A evals this and reports back.
    a.w.postMessage("self.postMessage({tag:'A',ran:true,evalType:typeof eval,hasTT:typeof self.trustedTypes})");
    b.w.postMessage('ignored-by-the-probe');

    // fetch as the pump -- real elapsed time without a timer
    const pump = async () => {
        for (let i = 0; i < 40; i++) {
            try { await fetch(location.href, { cache: 'no-store' }); } catch (e) { /* offline is fine */ }
            if (seen.some(([k]) => k === 'A') && seen.some(([k]) => k === 'B')) break;
        }
        for (const [k, v] of seen) {
            const key = k + (out[k] === undefined ? '' : '#' + Object.keys(out).length);
            out[key] = typeof v === 'object' ? v : String(v);
        }
        out.evalRan = seen.some(([k, v]) => k === 'A' && v && v.tag === 'A' && v.ran === true);
        out.messages = seen.length;
        try { a.w.terminate(); b.w.terminate(); URL.revokeObjectURL(a.url); URL.revokeObjectURL(b.url); } catch (e) { /* gone */ }
        return out;
    };
    return pump();
})()
