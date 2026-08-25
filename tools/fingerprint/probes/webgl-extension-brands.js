// Every extension name each context advertises, put back through getExtension
// and asked what it is. Chrome hands back a named interface object per
// extension -- [object OESTextureFloat], [object EXTBlendMinMax] -- so the brand
// is the ground truth this probe exists to capture, along with which of the
// members the extension carries.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/webgl-extension-brands.js --url https://example.com/ --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/webgl-extension-brands.js --url https://example.com/
(() => {
    const out = {};
    for (const v of ['webgl', 'webgl2']) {
        const gl = document.createElement('canvas').getContext(v);
        if (!gl) { out[v] = 'no-ctx'; continue; }
        const listed = gl.getSupportedExtensions();
        out[v + '.supported'] = listed;
        for (const name of listed) {
            const key = v + ' ' + name;
            try {
                // A fresh context per extension, so an earlier getExtension
                // cannot have changed what a later one answers.
                const own = document.createElement('canvas').getContext(v);
                const ext = own.getExtension(name);
                if (ext === null || ext === undefined) {
                    out[key] = String(ext);
                    continue;
                }
                const brand = Object.prototype.toString.call(ext);
                const proto = Object.getPrototypeOf(ext);
                const members = [];
                for (const k in ext) members.push(k);
                // The member values, which are what a script actually reads --
                // a GLenum here has to be the number Chrome reports, so it is
                // measured rather than transcribed from a spec page. Functions
                // are recorded by arity instead of value.
                const values = {};
                for (const k of proto ? Object.getOwnPropertyNames(proto) : []) {
                    if (k === 'constructor') continue;
                    const v = ext[k];
                    values[k] = typeof v === 'function' ? 'fn/' + v.length : v;
                }
                out[key] = {
                    brand: brand,
                    ctor: proto && proto.constructor ? proto.constructor.name : null,
                    // The interface object itself: Chrome has no global for an
                    // extension, so this should be undefined everywhere.
                    global: typeof globalThis[brand.slice(8, -1)],
                    members: members.sort(),
                    own: Object.getOwnPropertyNames(ext).sort(),
                    protoNames: proto ? Object.getOwnPropertyNames(proto).sort() : null,
                    values: values,
                };
            } catch (e) {
                out[key] = 'threw:' + (e && e.name);
            }
        }
    }
    return JSON.stringify(out);
})()
