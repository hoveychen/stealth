// Does the /tl payload carry the WebGL parameter strings?
//
// Same instrument as inject-b55-rect-pad.js. The read log has
// `WebGLRenderingContext.getParameter` called 153 times with a single distinct
// argument -- 37446, `UNMASKED_RENDERER_WEBGL` -- plus 13 calls on the WebGL2
// context across 10 arguments. A renderer string is the classic
// fingerprint-payload entry, and 153 calls for one value is a guard that wants
// it very much.
//
// A hundred characters onto every string answer. One occurrence carried is
// +220 on the body; 153 of them would be unmissable. A non-string answer is
// left alone: `getParameter` also returns numbers and typed arrays, and
// lengthening those would change what the caller can do with them.
(() => {
    let calls = 0;
    const PAD = 'z'.repeat(100);
    for (const name of ['WebGLRenderingContext', 'WebGL2RenderingContext']) {
        const proto = window[name] && window[name].prototype;
        if (!proto || typeof proto.getParameter !== 'function') continue;
        const real = proto.getParameter;
        try {
            Object.defineProperty(proto, 'getParameter', {
                configurable: true,
                writable: true,
                enumerable: false,
                value: function getParameter(pname) {
                    const v = real.call(this, pname);
                    if (typeof v !== 'string') return v;
                    calls++;
                    return v + PAD;
                },
            });
        } catch (e) { /* nothing to report to */ }
    }
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=glparam&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
