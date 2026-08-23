// Every operation's WebIDL `length`, on both engines, so a required-argument
// check can be turned on without inventing a throw Chrome does not do.
//
// `Function.prototype.length` on a WebIDL operation *is* the count Blink
// enforces: `document.createElement()` answers "1 argument required, but only 0
// present." and `document.createElement.length === 1`. So this sweep is the
// safety data for that check -- wherever our length exceeds Chrome's, enabling
// the check would throw on a call Chrome accepts, and wherever ours is smaller
// the check would stay silent where Chrome speaks.
//
// Walks every own function of every interface prototype reachable from a
// constructor on the global, plus the interface object's own statics, plus the
// bare functions on the global itself. Keys read `Element.prototype.matches`,
// `Response.json` (a static) or `window.fetch`.
//
// Run against a real http page (a trustworthy origin, or the [SecureContext]
// members are missing from the reading):
//
//   PROBE_PORT=<p> node tools/fingerprint/run-probe.mjs <engine> \
//       tools/fingerprint/probes/probe-operation-arity.js http://127.0.0.1:<q>/
(() => {
    const out = {};

    const record = (key, fn) => {
        if (typeof fn !== 'function') return;
        let len;
        try { len = fn.length; } catch { return; }
        if (typeof len !== 'number') return;
        out[key] = len;
    };

    // The own function-valued properties of one object, ignoring accessors: an
    // accessor pair has its own arity rule (a setter is always length 1) and is
    // not an operation.
    const walk = (obj, prefix) => {
        if (obj === null || typeof obj !== 'object' && typeof obj !== 'function') return;
        let names;
        try { names = Object.getOwnPropertyNames(obj); } catch { return; }
        for (const name of names) {
            if (name === 'constructor' || name === 'caller' || name === 'arguments') continue;
            let desc;
            try { desc = Object.getOwnPropertyDescriptor(obj, name); } catch { continue; }
            if (!desc || desc.get || desc.set) continue;
            record(`${prefix}.${name}`, desc.value);
        }
    };

    const globalNames = Object.getOwnPropertyNames(globalThis).sort();
    for (const name of globalNames) {
        let value;
        try { value = globalThis[name]; } catch { continue; }
        if (typeof value !== 'function') continue;

        // An interface object: it carries a prototype whose members are the
        // operations. A plain global function (fetch, setTimeout, atob) does not.
        const proto = value.prototype;
        if (proto && typeof proto === 'object') {
            walk(proto, `${name}.prototype`);
            walk(value, name);
            record(`new ${name}`, value);
        } else {
            record(`window.${name}`, value);
        }
    }

    return out;
})()
