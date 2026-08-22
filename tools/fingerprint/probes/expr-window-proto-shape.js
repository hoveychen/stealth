// Where a Window member actually lives. `[Global]` in Web IDL says the members
// are own properties of the global object and the interface prototype object
// keeps only the constants, so `Object.getPrototypeOf(window)` is exactly
// `Window.prototype` with three names on it. Both halves of that are readable
// from script in one expression, which is what this prints.
JSON.stringify({
    proto_is_window_prototype: Object.getPrototypeOf(window) === Window.prototype,
    proto_chain: (() => {
        const out = [];
        for (let o = Object.getPrototypeOf(window); o; o = Object.getPrototypeOf(o)) {
            const ctor = Object.getOwnPropertyDescriptor(o, 'constructor');
            out.push(ctor && typeof ctor.value === 'function' ? ctor.value.name : '<anonymous>');
        }
        return out;
    })(),
    window_prototype_own: Object.getOwnPropertyNames(Window.prototype).sort(),
    window_prototype_own_count: Object.getOwnPropertyNames(Window.prototype).length,
    window_own_count: Object.getOwnPropertyNames(window).length,
    window_own_symbols: Object.getOwnPropertySymbols(window).map(String),
    window_prototype_own_symbols: Object.getOwnPropertySymbols(Window.prototype).map(String),
    window_constructor_is_Window: window.constructor === Window,
    // A [Global] member is own on the global, not on the prototype.
    postMessage_own_on_window: Object.prototype.hasOwnProperty.call(window, 'postMessage'),
    postMessage_own_on_prototype: Object.prototype.hasOwnProperty.call(Window.prototype, 'postMessage'),
    document_own_on_window: Object.prototype.hasOwnProperty.call(window, 'document'),
    document_own_on_prototype: Object.prototype.hasOwnProperty.call(Window.prototype, 'document'),
    // ...but EventTarget's members are not flattened: they stay one hop up.
    addEventListener_own_on_window: Object.prototype.hasOwnProperty.call(window, 'addEventListener'),
    window_prototype_proto_is_EventTarget: Object.getPrototypeOf(Window.prototype) === EventTarget.prototype,
    // The constants Web IDL leaves behind on the interface prototype object.
    TEMPORARY: Object.getOwnPropertyDescriptor(Window.prototype, 'TEMPORARY') || null,
    PERSISTENT: Object.getOwnPropertyDescriptor(Window.prototype, 'PERSISTENT') || null,
})
