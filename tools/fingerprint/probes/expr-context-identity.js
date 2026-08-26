// Is the interface object reached through an instance the same object as the
// global of that name?
//
// The Akamai sensor calls one collector twice -- `TEY(fV)` then
// `TEY(window[<name>])` at offset 167084 of the sensor script -- and in Chrome
// only the first of the two builds a canvas and reads the renderer strings,
// while this engine builds one for each. A second pass over the same input is
// what a memo miss looks like, and the cheapest way for a memo keyed on the
// argument to miss is for the two arguments to be different objects where
// Chrome hands out one.
(() => {
    const out = {};
    const canvas = document.createElement('canvas');
    const ctxs = {
        '2d': canvas.getContext('2d'),
        webgl: document.createElement('canvas').getContext('webgl'),
        webgl2: document.createElement('canvas').getContext('webgl2'),
    };
    const expect = {
        '2d': 'CanvasRenderingContext2D',
        webgl: 'WebGLRenderingContext',
        webgl2: 'WebGL2RenderingContext',
    };
    for (const [k, ctx] of Object.entries(ctxs)) {
        const g = self[expect[k]];
        out[k] = ctx === null ? null : {
            ctorName: ctx.constructor && ctx.constructor.name,
            globalExists: typeof g,
            ctorIsGlobal: !!g && ctx.constructor === g,
            protoIsGlobalProto: !!g && Object.getPrototypeOf(ctx) === g.prototype,
            protoCtorIsGlobal: !!g && Object.getPrototypeOf(ctx).constructor === g,
            instanceOfGlobal: !!g && ctx instanceof g,
            canvasBack: ctx.canvas === canvas || ctx.canvas === undefined ? 'same-or-undefined' : 'other',
        };
    }
    // Same question for the element and for a second read of the same context.
    out.element = {
        ctorIsGlobal: canvas.constructor === self.HTMLCanvasElement,
        protoIsGlobalProto: Object.getPrototypeOf(canvas) === self.HTMLCanvasElement.prototype,
        secondGetContextSame: canvas.getContext('2d') === ctxs['2d'],
    };
    out.offscreen = typeof self.OffscreenCanvas === 'undefined' ? null : (() => {
        const o = new OffscreenCanvas(1, 1);
        const gl = o.getContext('webgl');
        return {
            width: o.width, height: o.height,
            ctorIsGlobal: o.constructor === self.OffscreenCanvas,
            glCtorName: gl && gl.constructor && gl.constructor.name,
            glCtorIsGlobal: !!gl && gl.constructor === self.WebGLRenderingContext,
            glCanvasIsOffscreen: !!gl && gl.canvas === o,
        };
    })();
    // The two arguments the sensor actually compares are a *constructor* and a
    // global of the same name, so check that shape directly for every interface
    // the canvas branch touches.
    out.viaInstance = {};
    for (const [k, ctx] of Object.entries(ctxs)) {
        if (!ctx) continue;
        const name = ctx.constructor.name;
        out.viaInstance[k] = {
            name,
            globalSame: self[name] === ctx.constructor,
            globalProtoSame: self[name] && self[name].prototype === Object.getPrototypeOf(ctx),
        };
    }
    return out;
})()
