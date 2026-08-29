// The `CSS` namespace object: own names, their descriptors, and the prototype.
//
// The Typed OM's numeric factories all live here -- `CSS.px(3)`,
// `CSS.deg(90)` -- so a page that reads any of them reads this object, and this
// engine carries three names where Chrome carries dozens. Descriptors and
// arity come along because a factory that exists but is enumerable, or takes
// the wrong number of arguments, is a different object from Chrome's.
(() => {
    const out = {};
    const names = Object.getOwnPropertyNames(CSS);
    out.count = names.length;
    out.names = names;
    out.prototypeIsObjectPrototype = Object.getPrototypeOf(CSS) === Object.prototype;
    out.prototypeName = (() => {
        const p = Object.getPrototypeOf(CSS);
        if (p === null) return 'null';
        if (p === Object.prototype) return 'Object.prototype';
        return String(p);
    })();
    out.toStringTag = Object.prototype.toString.call(CSS);

    out.descriptors = {};
    for (const n of names) {
        const d = Object.getOwnPropertyDescriptor(CSS, n);
        const kind = typeof CSS[n];
        out.descriptors[n] = {
            kind,
            writable: d.writable,
            enumerable: d.enumerable,
            configurable: d.configurable,
            length: kind === 'function' ? CSS[n].length : undefined,
            fnName: kind === 'function' ? CSS[n].name : undefined,
        };
    }

    // What a factory actually returns, for the shapes a page can compare.
    out.samples = {};
    for (const n of ['px', 'em', 'deg', 'percent', 'number', 's', 'fr', 'cqw', 'dvw']) {
        try {
            const v = CSS[n](3);
            out.samples[n] = {
                str: String(v),
                unit: v.unit,
                value: v.value,
                ctor: v.constructor && v.constructor.name,
                tag: Object.prototype.toString.call(v),
            };
        } catch (e) {
            out.samples[n] = (e.name || 'Error') + ': ' + e.message;
        }
    }
    return JSON.stringify(out, null, 1);
})()
