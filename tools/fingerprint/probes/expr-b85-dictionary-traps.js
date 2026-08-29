// How a WebIDL dictionary is read out of a JS object.
//
// Kasada's payload carries a Proxy trap log, and ours is longer than Chrome's:
// four `h:` entries against one, because this engine probes dictionary members
// with [[Has]] where Chrome uses [[Get]]. Decoded from the guard's own payload
// with the `htokens` knob.
//
// Three things to pin before changing the bridge: which traps fire and in what
// order, which member names are read, and whether an inherited dictionary's
// members come before or after the ones that inherit them.
(() => {
    const out = {};

    const record = (label, build) => {
        const log = [];
        const target = {};
        const handler = {
            has(t, k) { log.push('has:' + String(k)); return Reflect.has(t, k); },
            get(t, k, r) { log.push('get:' + String(k)); return Reflect.get(t, k, r); },
            getOwnPropertyDescriptor(t, k) { log.push('gopd:' + String(k)); return Reflect.getOwnPropertyDescriptor(t, k); },
            ownKeys(t) { log.push('ownKeys'); return Reflect.ownKeys(t); },
        };
        const proxy = new Proxy(target, handler);
        let threw = null;
        try { build(proxy); } catch (e) { threw = (e.name || 'Error') + ': ' + e.message; }
        out[label] = {
            traps: log,
            kinds: [...new Set(log.map((l) => l.split(':')[0]))],
            names: log.filter((l) => l.startsWith('get:') || l.startsWith('has:')).map((l) => l.split(':')[1]),
            threw,
        };
    };

    // `RequestInit` -- the one the guard hands a Proxy to.
    record('Request', (init) => new Request('https://example.com/', init));
    // An event dictionary with an inherited chain: InputEventInit inherits
    // UIEventInit inherits EventInit. Whether the base members are read first
    // is what says how the chain is walked.
    record('InputEvent', (init) => new InputEvent('input', init));
    record('CustomEvent', (init) => new CustomEvent('x', init));
    record('MouseEvent', (init) => new MouseEvent('click', init));
    // A non-event dictionary, to check the rule is the bridge's and not the
    // event constructors'.
    record('URLSearchParams-like/observe', (init) => {
        const el = document.createElement('div');
        new IntersectionObserver(() => {}, init).observe(el);
    });
    record('scrollTo', (init) => document.createElement('div').scrollTo(init));
    record('addEventListener', (init) => {
        document.createElement('div').addEventListener('x', () => {}, init);
    });

    return JSON.stringify(out, null, 1);
})()
