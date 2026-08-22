// The nameless object Web IDL calls the "named properties object": for a
// [Global] interface with a named property getter it sits between the interface
// prototype object and EventTarget.prototype, so `window`'s chain is four links
// deep even though `Window.prototype` carries three names. This prints what is
// readable about that link.
JSON.stringify((() => {
    const np = Object.getPrototypeOf(Window.prototype);
    return {
        exists: np !== null,
        is_EventTarget_prototype: np === EventTarget.prototype,
        own_names: np ? Object.getOwnPropertyNames(np).sort() : null,
        own_symbols: np ? Object.getOwnPropertySymbols(np).map(String) : null,
        to_string_tag: np ? (Object.getOwnPropertyDescriptor(np, Symbol.toStringTag) || null) : null,
        brand: np ? Object.prototype.toString.call(np) : null,
        constructor_descriptor: np ? (Object.getOwnPropertyDescriptor(np, 'constructor') || null) : null,
        next_is_EventTarget_prototype: np ? Object.getPrototypeOf(np) === EventTarget.prototype : null,
        // What the interface prototype object itself is branded with.
        window_prototype_tag: Object.getOwnPropertyDescriptor(Window.prototype, Symbol.toStringTag) || null,
        window_prototype_constructor: Object.getOwnPropertyDescriptor(Window.prototype, 'constructor') || null,
        window_brand: Object.prototype.toString.call(window),
    };
})())
