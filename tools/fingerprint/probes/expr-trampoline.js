// The station's own eval trampoline, run offline against both engines.
//
// The Turnstile widget builds a 291-byte blob worker whose whole program is an
// `eval` of whatever the document posts in, and asks it a fixed list of
// questions (README, "The worker was never released, and the probes it runs are
// readable"). The question sources below are verbatim from
// `results/fopt-e1-oracle.json`, minus the two that carry a per-session
// challenge token and so cannot be replayed. The answers are what Cloudflare
// reads, so this is the diff that matters, and it needs no station to take it.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-trampoline.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-trampoline.js
(function () {
    var TRAMPOLINE = "var _p=null;if(self.trustedTypes)try{_p=self.trustedTypes.createPolicy('Kssz2',"
        + "{createScript:function(s){return s;}})}catch(e){self.postMessage({type:'tt-policy-error',"
        + "msg:e.message})}\n"
        + "onmessage=function(e){e.isTrusted&&''===e.origin&&null===e.source&&"
        + "eval(_p?_p.createScript(e.data):e.data)}";

    // Each entry: the key the answer arrives under, and the source posted in.
    var PROBES = [
        ['nav',
            'var n=self.navigator;postMessage({ cDfY2:n.platform,aLKoi3:n.languages,'
            + 'mRDZ3:n.hardwareConcurrency,ibdUe0:n.deviceMemory,udfQI1:n.userAgent});'],
        ['clock',
            'for(var a=1,b=1,c,d=0;5E3>d;d++){var e=performance.now(),f=performance.now();'
            + 'e<f&&(c=f-e,c>a&&c<b?b=c:c<a&&(b=a,a=c))}postMessage({ EZRaP0:a});'],
        ['opfs',
            '~function(){navigator.storage.getDirectory().then(function(z){var I="Itvrd0",f={};'
            + 'f["create"]=!![],z.getFileHandle(I,f).then(function(g){return g.createSyncAccessHandle()})'
            + '.then(function(g){var X=new Uint8Array(1),Y={};Y["at"]=0,g.write(X,Y);'
            + 'var N=performance.now();g.flush();var l=performance.now()-N;g.close();var r={};'
            + 'r["vZBc4"]=l,self.postMessage(r)}).catch(function(g){'
            + 'self.postMessage({"Tltp4":(g.message||String(g)).substring(0,100)})})'
            + '}).catch(function(U){self.postMessage({"Tltp4":(U.message||String(U)).substring(0,100)})})}();'],
        ['debugger',
            'eval(_p?_p.createScript("debugger"):"debugger");postMessage({ hpoXC5:"uyTve9"});'],
        ['timeout',
            'setTimeout(function(){self.postMessage({ PpJy7:"1"})},55)'],
        // Not one of theirs. The recorder saw a digest argument arrive as a
        // plain object on one arm and a typed-array view on the other, and the
        // difference is one instanceof.
        ['typedarray',
            'var u=new Uint8Array(4);postMessage({ buf:u.buffer instanceof ArrayBuffer,'
            + 'view:ArrayBuffer.isView(u),ctor:String(u.buffer&&u.buffer.constructor&&u.buffer.constructor.name)});'],
    ];

    var out = {};
    var w;
    try {
        w = new Worker(URL.createObjectURL(new Blob([TRAMPOLINE], { type: 'text/javascript' })));
    } catch (e) {
        return { error: String(e) };
    }

    // One question at a time, so an answer cannot be attributed to the wrong
    // probe: the station interleaves them but nothing here needs to.
    function ask(i) {
        return new Promise(function (resolve) {
            if (i >= PROBES.length) return resolve();
            var name = PROBES[i][0];
            var done = false;
            var timer = setTimeout(function () {
                if (done) return;
                done = true;
                out[name] = { timedOut: true };
                w.removeEventListener('message', onMsg);
                resolve(ask(i + 1));
            }, 1200);
            function onMsg(ev) {
                if (done) return;
                done = true;
                clearTimeout(timer);
                out[name] = ev.data;
                w.removeEventListener('message', onMsg);
                resolve(ask(i + 1));
            }
            w.addEventListener('message', onMsg);
            try {
                w.postMessage(PROBES[i][1]);
            } catch (e) {
                if (done) return;
                done = true;
                clearTimeout(timer);
                out[name] = { postFailed: String(e) };
                w.removeEventListener('message', onMsg);
                resolve(ask(i + 1));
            }
        });
    }

    // Whether the page can even ask the OPFS question is half of it: the widget
    // only posts a probe it has feature-detected, so a missing entry point is a
    // probe that never appears on the wire.
    out.gates = {
        storage: typeof navigator.storage,
        getDirectory: !!(navigator.storage && navigator.storage.getDirectory),
        trustedTypes: typeof self.trustedTypes,
    };

    return ask(0).then(function () {
        try { w.terminate(); } catch (e) { /* gone */ }
        return out;
    });
})();
