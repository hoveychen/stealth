// Does the /tl payload carry the plugin and mime-type lists?
//
// Same instrument as inject-b55-rect-pad.js. The read log has
// `Navigator.plugins` 32 times, `Plugin.name` 15, `Plugin.description` 10,
// `MimeType.type` 20 and `MimeType.suffixes` 20, and 30 iterator steps through
// a `PluginArray` -- a guard walking both lists element by element. Chrome's
// five hard-coded PDF plugins and two mime types are a fixed 400-odd characters
// of identity, and a list that is short here is exactly the shape of deficit
// being hunted.
//
// Thirty characters onto each string field of each entry.
(() => {
    let calls = 0;
    const PAD = 'z'.repeat(30);
    const wrap = (proto, names) => {
        if (!proto) return;
        for (const name of names) {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.get) continue;
            const get = d.get;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true,
                    enumerable: d.enumerable,
                    get() { calls++; return String(get.call(this)) + PAD; },
                });
            } catch (e) { /* nothing to report to */ }
        }
    };
    wrap(window.Plugin && Plugin.prototype, ['name', 'description', 'filename']);
    wrap(window.MimeType && MimeType.prototype, ['type', 'description', 'suffixes']);
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=plugins&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
