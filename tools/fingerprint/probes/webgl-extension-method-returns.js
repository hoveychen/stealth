// What every WebGL extension method answers. The interface objects match Chrome
// now (probes/webgl-extension-brands.js) and their methods have Chrome's arity,
// but every one of them is a no-op here: `fn.length` is right and the return
// value is `undefined`. Most of the 37 return nothing in Chrome either, so this
// probe exists to find which ones do -- getSupportedProfiles, isVertexArrayOES
// and getTranslatedShaderSource are the three already suspected, and a list
// arrived at by reading names is a list with holes in it.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/webgl-extension-method-returns.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/webgl-extension-method-returns.js --url https://example.com/
(() => {
    const out = {};
    const describe = (v) => {
        if (v === undefined) return 'undefined';
        if (v === null) return 'null';
        const t = typeof v;
        if (t === 'boolean' || t === 'number' || t === 'string') return t + ':' + JSON.stringify(v);
        if (Array.isArray(v)) return 'array:' + JSON.stringify(v);
        return Object.prototype.toString.call(v);
    };

    // Arguments per method, so what comes back is what a real call produces
    // rather than what a type error produces. A method absent from here is
    // called with its arity in nulls, which is enough for a command that
    // returns nothing. `ctx` memoises the objects a call needs -- a query, a
    // vertex array, a compiled shader -- per extension.
    const ARGS = {
        beginQueryEXT: (gl, ext, ctx) => [ext.TIME_ELAPSED_EXT, ctx.query()],
        deleteQueryEXT: (gl, ext, ctx) => [ctx.query()],
        endQueryEXT: (gl, ext) => [ext.TIME_ELAPSED_EXT],
        getQueryEXT: (gl, ext) => [ext.TIME_ELAPSED_EXT, ext.CURRENT_QUERY_EXT],
        getQueryObjectEXT: (gl, ext, ctx) => [ctx.query(), ext.QUERY_RESULT_AVAILABLE_EXT],
        isQueryEXT: (gl, ext, ctx) => [ctx.query()],
        queryCounterEXT: (gl, ext, ctx) => [ctx.query(), ext.TIMESTAMP_EXT],

        bindVertexArrayOES: (gl, ext, ctx) => [ctx.vao()],
        deleteVertexArrayOES: (gl, ext, ctx) => [ctx.vao()],
        isVertexArrayOES: (gl, ext, ctx) => [ctx.vao()],

        getTranslatedShaderSource: (gl, ext, ctx) => [ctx.shader()],
        drawBuffersWEBGL: (gl) => [[gl.BACK]],
        polygonModeWEBGL: (gl, ext) => [ext.FRONT_AND_BACK_WEBGL ?? 0x0408, ext.LINE_WEBGL ?? 0x1B01],
        provokingVertexWEBGL: (gl, ext) => [ext.FIRST_VERTEX_CONVENTION_WEBGL ?? 0x8E4D],
        clipControlEXT: (gl, ext) => [ext.LOWER_LEFT_EXT, ext.NEGATIVE_ONE_TO_ONE_EXT],
    };

    for (const ver of ['webgl', 'webgl2']) {
        const probe = document.createElement('canvas').getContext(ver);
        if (!probe) { out[ver] = 'no-ctx'; continue; }
        for (const name of probe.getSupportedExtensions()) {
            // A fresh context per extension: loseContext() is one of the
            // methods being called, and a lost context would answer for every
            // extension after it.
            const gl = document.createElement('canvas').getContext(ver);
            const ext = gl.getExtension(name);
            if (!ext) { out[ver + ' ' + name] = 'no-ext'; continue; }
            const memo = {};
            const ctx = {
                query: () => memo.q ??= (ext.createQueryEXT ? ext.createQueryEXT() : gl.createQuery?.() ?? null),
                vao: () => memo.v ??= (ext.createVertexArrayOES ? ext.createVertexArrayOES() : gl.createVertexArray?.() ?? null),
                shader: () => memo.s ??= (() => {
                    const sh = gl.createShader(gl.VERTEX_SHADER);
                    gl.shaderSource(sh, 'void main(){gl_Position=vec4(0.0,0.0,0.0,1.0);}');
                    gl.compileShader(sh);
                    return sh;
                })(),
            };
            const proto = Object.getPrototypeOf(ext);
            for (const m of Object.getOwnPropertyNames(proto).sort()) {
                if (m === 'constructor') continue;
                if (typeof ext[m] !== 'function') continue;
                const key = ver + ' ' + name + '.' + m;
                try {
                    const args = ARGS[m] ? ARGS[m](gl, ext, ctx) : new Array(ext[m].length).fill(null);
                    out[key] = describe(ext[m](...args));
                } catch (e) {
                    out[key] = 'threw:' + (e && e.name) + ':' + (e && e.message);
                }
            }
        }
    }
    return JSON.stringify(out);
})()
