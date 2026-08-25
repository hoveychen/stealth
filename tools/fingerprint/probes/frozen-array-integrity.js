// What a FrozenArray-returning getter actually hands back: frozen, sealed, or
// an ordinary array. Three of them, one empty and two not, because an empty
// array can look frozen for the wrong reason.
(() => {
    const out = {};
    const look = (key, make) => {
        try {
            const a = make();
            out[key] = [
                Array.isArray(a), a.length, Object.isFrozen(a), Object.isSealed(a),
                Object.isExtensible(a), a.constructor === Array,
            ].join('|');
            const d = Object.getOwnPropertyDescriptor(a, '0');
            out[key + ' [0]'] = d ? [d.writable, d.enumerable, d.configurable].join('|') : 'absent';
            const len = Object.getOwnPropertyDescriptor(a, 'length');
            out[key + ' length'] = [len.writable, len.enumerable, len.configurable].join('|');
            out[key + ' fresh'] = make() !== make();
        } catch (e) {
            out[key] = 'threw:' + (e && e.name) + ':' + (e && e.message);
        }
    };

    look('viewport.segments', () => visualViewport.segments ?? navigator.windowControlsOverlay);
    look('viewport.segments2', () => window.viewport && window.viewport.segments);
    look('input.webkitEntries', () => {
        const i = document.createElement('input');
        i.type = 'file';
        return i.webkitEntries;
    });
    look('metadata.artwork', () => new MediaMetadata({
        artwork: [{ src: 'http://x/y.png', sizes: '96x96', type: 'image/png' }],
    }).artwork);
    look('metadata.artwork empty', () => new MediaMetadata({}).artwork);
    // Two more FrozenArrays for comparison, so the answer is a rule and not a
    // property of one getter.
    look('navigator.languages', () => navigator.languages);
    look('performance.getEntries', () => performance.getEntries());
    out['has window.viewport'] = typeof window.viewport;
    out['has visualViewport.segments'] = typeof visualViewport.segments;
    return out;
})()
