// Why is `speechSynthesis.getVoices()` empty on this arm when Kasada hashes it?
//
// The funnel capture (inject-b55-funnels.js) found the biggest readable
// difference between the arms at x-hyatt: Kasada joins the voice list into
// `name,voiceURI,lang,localService,default;` records and hashes the result.
// Chrome hands it 9619 characters -- about a hundred macOS voices -- and this
// engine hands it the empty string.
//
// This engine *has* the list (webapi/speech/voices.zig, 199 entries). It
// withholds it for a measured 665ms after the first getVoices() call, because
// that is what a headed Chrome does: the first read is always empty and the
// list completes at 668/675/675ms. So an empty answer here is either the list
// genuinely never arriving or Kasada reading inside that window -- and this
// engine reaches the POST at 811ms where Chrome takes 1884ms, which would put
// the two arms on opposite sides of the same 665ms.
//
// Those are different findings with different fixes, and one timestamp
// separates them. Record when each getVoices() call happens and how many voices
// it returned, on both arms, and report the sequence. Also record the keyboard
// layout map, which is the other empty answer the funnels found, and the
// `style` attributes Kasada writes, which is where its `0px,0px,0px,0px`
// readback comes from.
//
// Beacons, not console: a station run has no console, because antibot-sweep
// never sends Runtime.enable.
(() => {
    const t0 = Date.now();
    const log = [];
    const at = () => Date.now() - t0;

    if (window.speechSynthesis && typeof speechSynthesis.getVoices === 'function') {
        const real = speechSynthesis.getVoices;
        try {
            speechSynthesis.getVoices = function getVoices() {
                const v = real.call(this);
                log.push('voices@' + at() + '=' + (v ? v.length : 'null'));
                return v;
            };
        } catch (e) { /* */ }
        // An independent poll, so the answer does not depend on the page asking.
        for (const d of [0, 200, 500, 700, 900, 1500, 2500]) {
            setTimeout(() => {
                try { log.push('poll@' + at() + '=' + real.call(speechSynthesis).length); } catch (e) { /* */ }
            }, d);
        }
    } else {
        log.push('voices=absent');
    }

    if (navigator.keyboard && typeof navigator.keyboard.getLayoutMap === 'function') {
        const real = navigator.keyboard.getLayoutMap;
        try {
            navigator.keyboard.getLayoutMap = function getLayoutMap() {
                const at0 = at();
                return real.call(this).then((m) => {
                    log.push('layout@' + at0 + '=' + (m && m.size !== undefined ? m.size : '?'));
                    return m;
                });
            };
        } catch (e) { /* */ }
    } else {
        log.push('keyboard=absent');
    }

    const proto = window.Element && Element.prototype;
    if (proto && typeof proto.setAttribute === 'function') {
        const real = proto.setAttribute;
        try {
            Object.defineProperty(proto, 'setAttribute', {
                configurable: true, writable: true, enumerable: false,
                value: function setAttribute(name, value) {
                    if (String(name).toLowerCase() === 'style') log.push('style@' + at() + '=' + String(value).slice(0, 160));
                    return real.call(this, name, value);
                },
            });
        } catch (e) { /* */ }
    }

    const send = (q) => { try { new Image().src = 'https://www.hyatt.com/__b55v?' + q; } catch (e) { /* */ } };
    let n = 0;
    const flush = () => {
        while (log.length) {
            const line = log.shift();
            send('n=' + (n++) + '&v=' + encodeURIComponent(line));
        }
    };
    // Flush repeatedly rather than once: the passing arm navigates into the site
    // as soon as the guard clears and takes the document's timers with it, so a
    // single late report loses everything the short-lived document saw.
    for (const d of [1000, 1600, 2200, 3000, 4000, 6000, 10000]) setTimeout(flush, d);
})();
