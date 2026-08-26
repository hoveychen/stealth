// Does the /tl payload carry the canvas data URLs?
//
// Same instrument as inject-b55-rect-pad.js. The read log has
// `HTMLCanvasElement.toDataURL` called 80 times with 80 distinct mime
// arguments, which is a guard walking the format table rather than reading one
// image.
//
// This is a measurement, not a candidate change: three canvas plans stand off
// this surface by instruction, and what is asked here is only whether those
// answers reach the payload and how many bytes of them do. Twenty characters
// per answer; 80 answers carried would be about 3500 bytes on the body.
(() => {
    let calls = 0;
    const PAD = 'z'.repeat(20);
    for (const name of ['HTMLCanvasElement', 'OffscreenCanvas']) {
        const proto = window[name] && window[name].prototype;
        if (!proto || typeof proto.toDataURL !== 'function') continue;
        const real = proto.toDataURL;
        try {
            Object.defineProperty(proto, 'toDataURL', {
                configurable: true,
                writable: true,
                enumerable: false,
                value: function toDataURL(...args) {
                    calls++;
                    return String(real.apply(this, args)) + PAD;
                },
            });
        } catch (e) { /* nothing to report to */ }
    }
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=todataurl&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
