// Capture what Kasada actually feeds into its payload, on both arms, at the
// three funnels every value has to pass through before it is posted.
//
// P1 of this plan showed which families reach the `/tl` body by lengthening
// them and watching `postLen` move. That answers "is it in there" but not "how
// many bytes of it are missing here", because the body is the *encoded* form
// and the encoding inflates content by about 2.06x. This probe reads the
// content side directly.
//
// The read log for this station (results/b53-reads-x-hyatt.json) shows the
// funnels: `TextEncoder.encode` ten times, `Window.btoa` three times,
// `SubtleCrypto.digest` three times, and one `XMLHttpRequest.send`. The encode
// arguments the log caught are the payload's sections in plaintext -- one of
// them is literally `180px,180px,180px,180px`, another
// `71,94,235,94,323,94,59,111,160,8,7,464` -- but the log truncates each at a
// hundred characters and only exists for this engine. Hooking the funnels from
// JS captures them whole and works identically in Chrome, which is the only way
// to get a per-section byte difference between the two arms.
//
// Reporting is by beacon, because a station run has no console: antibot-sweep
// never sends Runtime.enable, since Kasada withholds clearance from a client
// that has. The beacons fire five seconds in; the `/tl` POST goes out at about
// 800ms, so nothing here can be inside the body it is measuring. antibot-sweep
// records every request URL under --trace, so the query strings are the wire.
(() => {
    const rec = [];
    let bigSeen = false;
    const note = (tag, v) => {
        let s;
        try { s = typeof v === 'string' ? v : String(v); } catch (e) { s = '<unstringifiable>'; }
        rec.push({ tag, len: s.length, val: s });
        // A section over five thousand characters is the serialised payload, and
        // the frame that builds it is short-lived on the passing arm: Chrome's
        // blob: iframe is torn down when the guard clears and the top document
        // navigates into the site, taking every pending timer with it. Report
        // right after it appears. The payload string exists before the POST that
        // carries it, so a beacon here cannot be inside the body it reports.
        if (!bigSeen && s.length > 5000) {
            bigSeen = true;
            // The serialised payload is a JSON array of `<n>:<base64>` tokens.
            // Its own text is ciphertext and a prefix of it compares nothing,
            // but the *shape* -- how many tokens and how long each is -- lines
            // up across the arms, which is what turns "we are 524 characters
            // short" into "we are short in token 7".
            try {
                if (s[0] === '[') {
                    const arr = JSON.parse(s);
                    if (Array.isArray(arr)) {
                        // `<key>:<base64>`, and the array is emitted in a
                        // different order on each run, so the key is the only
                        // thing that lines a token up with its opposite number
                        // in the other arm.
                        note('struct', arr.map((e) => {
                            const t = String(e);
                            const c = t.indexOf(':');
                            return (c > 0 && c < 8 ? t.slice(0, c) : '?') + ':' + t.length;
                        }).join(','));
                    }
                }
            } catch (e) { /* not an array, or not JSON: the length still stands */ }
            setTimeout(report, 150);
        }
    };

    const hookMethod = (proto, name, tag, pick) => {
        if (!proto || typeof proto[name] !== 'function') return;
        const real = proto[name];
        try {
            Object.defineProperty(proto, name, {
                configurable: true, writable: true, enumerable: false,
                value: function (...args) {
                    try { note(tag, pick(args, this)); } catch (e) { /* */ }
                    return real.apply(this, args);
                },
            });
        } catch (e) { /* nothing to report to */ }
    };

    hookMethod(window.TextEncoder && TextEncoder.prototype, 'encode', 'enc', (a) => (a[0] === undefined ? '' : a[0]));
    hookMethod(window, 'btoa', 'btoa', (a) => a[0]);
    hookMethod(window.XMLHttpRequest && XMLHttpRequest.prototype, 'send', 'xhr', (a) => (a[0] === undefined ? '' : a[0]));
    // digest takes a BufferSource; its byte length is the interesting figure and
    // its bytes are not printable, so record the length as the value.
    if (window.crypto && crypto.subtle && typeof crypto.subtle.digest === 'function') {
        const real = crypto.subtle.digest;
        try {
            crypto.subtle.digest = function digest(alg, data) {
                try {
                    const n = data && (data.byteLength !== undefined ? data.byteLength : data.length);
                    note('digest', String(alg && alg.name ? alg.name : alg) + ':' + n);
                } catch (e) { /* */ }
                return real.call(this, alg, data);
            };
        } catch (e) { /* */ }
    }

    const BASE = 'https://www.hyatt.com/__b55f?';
    const beacons = [];
    const send = (q) => { try { new Image().src = BASE + q; } catch (e) { /* */ } };

    let reported = false;
    const report = () => {
        if (reported || !rec.length) return;
        reported = true;
        // One summary line first: every record's tag and length, in order, so a
        // run whose value beacons get lost still yields the byte counts that the
        // deficit is measured in.
        send('sum=' + encodeURIComponent(rec.map((r, i) => i + ':' + r.tag + ':' + r.len).join(',')).slice(0, 1600));
        // Then the sections themselves, chunked. A long one is sent only as a
        // 1200-character prefix: that is enough to tell a keyboard layout from a
        // codec list from the serialised payload, and the summary above already
        // carries every full length.
        rec.forEach((r, i) => {
            const cap = Math.min(r.len, r.tag === 'struct' ? 6000 : 1200);
            for (let off = 0; off < cap; off += 300) {
                beacons.push('i=' + i + '&t=' + r.tag + '&o=' + off + '&v=' + encodeURIComponent(r.val.slice(off, off + 300)));
            }
        });
        // Spread them out: a burst of a hundred image requests is its own signal,
        // and nothing downstream is waiting on them.
        beacons.forEach((q, k) => setTimeout(() => send(q), 20 * k));
    };
    // The refused arm sits on its 429 and a five-second timer is safe there, but
    // the passing arm reloads into the site as soon as the guard clears and
    // takes every pending timer of the refused document with it. So report at
    // 2200ms -- past the `/tl` POST, which goes out at 861ms here and 1884ms in
    // Chrome -- and again later in case the first pass had nothing yet.
    for (const t of [2200, 4000, 8000, 15000]) setTimeout(report, t);
})();
