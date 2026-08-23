// The DOM throwers a page reaches in one line, plus the two `getRandomValues`
// rejections. The parent sweep (`/tmp/expr-error-message-text.js`, 28 cases)
// found that `name`, `code` and the constructor already agree with Chrome
// everywhere -- only `message` diverges, because Blink prefixes every one of
// these with `Failed to execute '<op>' on '<Interface>': ` and then says
// something specific about the argument it was handed.
//
// This probe widens that reading where the wording is *parameterised*: the tag
// name and the selector are echoed back into the sentence, the interface name
// follows the receiver (Document / Element / DocumentFragment), and
// `getRandomValues` quotes both the view's type and its byte length. A single
// case per family would not catch getting the interpolation wrong.
(() => {
    const el = () => document.createElement('div');
    const frag = () => document.createDocumentFragment();

    const cases = {
        // createElement: the tag is echoed, quoted, inside the sentence.
        "createElement('')": () => document.createElement(''),
        "createElement('1x')": () => document.createElement('1x'),
        "createElement('a b')": () => document.createElement('a b'),
        "createElement('<')": () => document.createElement('<'),
        "createElementNS(null,'1x')": () => document.createElementNS(null, '1x'),

        // querySelector: the selector is echoed, and empty has its own sentence.
        "document.querySelector('###')": () => document.querySelector('###'),
        "document.querySelector('')": () => document.querySelector(''),
        "document.querySelectorAll('###')": () => document.querySelectorAll('###'),
        "document.querySelectorAll('')": () => document.querySelectorAll(''),
        "element.querySelector('###')": () => el().querySelector('###'),
        "element.querySelectorAll('')": () => el().querySelectorAll(''),
        "fragment.querySelector('###')": () => frag().querySelector('###'),
        "element.matches('###')": () => el().matches('###'),
        "element.closest('###')": () => el().closest('###'),

        // setAttribute: the attribute name is echoed.
        "setAttribute('','v')": () => el().setAttribute('', 'v'),
        "setAttribute('a b','v')": () => el().setAttribute('a b', 'v'),
        "setAttribute('1x','v')": () => el().setAttribute('1x', 'v'),
        "getAttribute('a b')": () => el().getAttribute('a b'),
        "setAttributeNS(null,'a b','v')": () => el().setAttributeNS(null, 'a b', 'v'),

        // Node mutation: several distinct HierarchyRequestError sentences.
        'appendChild(self)': () => { const d = el(); d.appendChild(d); },
        'appendChild(ancestor)': () => { const a = el(), b = el(); a.appendChild(b); b.appendChild(a); },
        'appendChild(document)': () => el().appendChild(document),
        'insertBefore(wrong ref)': () => el().insertBefore(el(), el()),
        'removeChild(not a child)': () => el().removeChild(el()),
        'replaceChild(not a child)': () => el().replaceChild(el(), el()),

        // getRandomValues: type name and byte length are both echoed.
        'getRandomValues(Float64Array)': () => crypto.getRandomValues(new Float64Array(1)),
        'getRandomValues(Float32Array)': () => crypto.getRandomValues(new Float32Array(1)),
        'getRandomValues(65537 bytes)': () => crypto.getRandomValues(new Uint8Array(65537)),
        'getRandomValues(Uint16 65536)': () => crypto.getRandomValues(new Uint16Array(65536)),
        // The bytes are random, so read back the identity of the view instead:
        // an integer type is filled in place and handed back, not rejected.
        'getRandomValues(BigInt64Array)': () => {
            const v = new BigInt64Array(1);
            return crypto.getRandomValues(v) === v;
        },
        'getRandomValues(DataView)': () => crypto.getRandomValues(new DataView(new ArrayBuffer(8))),

        // structuredClone: the value is stringified into the sentence.
        'structuredClone(fn)': () => structuredClone(() => { }),
        'structuredClone(symbol)': () => structuredClone(Symbol('s')),
        'structuredClone(element)': () => structuredClone(el()),
    };

    const out = {};
    for (const [name, fn] of Object.entries(cases)) {
        try {
            const v = fn();
            out[name] = { throws: false, returned: typeof v === 'string' ? JSON.stringify(v) : String(v) };
        } catch (e) {
            out[name] = {
                throws: true,
                ctor: e?.constructor?.name ?? typeof e,
                name: e?.name ?? null,
                code: e instanceof DOMException ? e.code : undefined,
                message: e?.message ?? String(e),
            };
        }
    }
    return JSON.stringify(out);
})()
