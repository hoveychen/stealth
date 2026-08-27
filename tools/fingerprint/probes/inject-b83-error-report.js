// What we are telling Kasada's own error endpoint.
//
// A --trace run of x-hyatt shows two requests to `https://reporting.cdndex.io/
// error` -- one XHR, one fetch -- alongside the `/tl` POST. That is Kasada's
// error channel: the widget caught something and reported it. A browser that
// the widget runs cleanly on has nothing to report there, so the body is a
// description of this engine written by the guard itself.
//
// Captures three things and beacons them back through the station's own origin
// (antibot-sweep records every request URL under --trace, and a station run
// sends no Runtime.enable, so there is no console to print to):
//
//   * the body of anything sent to cdndex.io, by XHR or fetch;
//   * uncaught errors and unhandled rejections, with their stacks;
//   * console.error, which is where a caught-and-logged failure would go.
(() => {
    const rec = [];
    const push = (tag, s) => {
        try { rec.push(tag + '=' + String(s)); } catch (e) { /* */ }
    };

    // Everything, not just cdndex: a probe that reports nothing cannot be told
    // apart from a probe whose hooks never went on, and the first run of this
    // one came back empty.
    const isReport = () => true;

    const X = window.XMLHttpRequest && XMLHttpRequest.prototype;
    if (X) {
        const open = X.open;
        const send = X.send;
        try {
            X.open = function (method, url) {
                try { this.__b83url = url; } catch (e) { /* */ }
                return open.apply(this, arguments);
            };
            X.send = function (body) {
                try {
                    if (isReport(this.__b83url)) push('xhr:' + this.__b83url, body);
                } catch (e) { /* */ }
                return send.apply(this, arguments);
            };
        } catch (e) { /* */ }
    }

    if (typeof window.fetch === 'function') {
        const real = window.fetch;
        try {
            window.fetch = function (input, init) {
                try {
                    const url = typeof input === 'string' ? input : (input && input.url);
                    if (isReport(url)) push('fetch:' + url, init && init.body);
                } catch (e) { /* */ }
                return real.apply(this, arguments);
            };
        } catch (e) { /* */ }
    }

    window.addEventListener('error', (e) => {
        push('onerror', (e.message || '') + ' @ ' + (e.filename || '') + ':' + e.lineno + ' | ' +
            ((e.error && e.error.stack) || ''));
    }, true);
    window.addEventListener('unhandledrejection', (e) => {
        const r = e.reason;
        push('rejection', (r && (r.stack || r.message)) || String(r));
    }, true);

    if (window.console && typeof console.error === 'function') {
        const real = console.error;
        console.error = function () {
            push('console.error', Array.prototype.map.call(arguments, (a) => {
                try { return (a && a.stack) || String(a); } catch (e) { return '?'; }
            }).join(' '));
            return real.apply(this, arguments);
        };
    }

    const BASE = 'https://www.hyatt.com/__b83e?';
    let sent = 0;
    const report = () => {
        if (rec.length === sent) return;
        const from = sent;
        sent = rec.length;
        // Chunked the way inject-b55-funnels.js chunks: one image per 300
        // characters, spread out so a burst is not its own signal.
        rec.slice(from).forEach((r, k) => {
            for (let off = 0; off < Math.min(r.length, 3000); off += 300) {
                const q = 'i=' + (from + k) + '&o=' + off + '&v=' + encodeURIComponent(r.slice(off, off + 300));
                setTimeout(() => { try { new Image().src = BASE + q; } catch (e) { /* */ } }, 20 * (off / 300 + k * 12));
            }
        });
    };
    if (typeof navigator.sendBeacon === 'function') {
        const real = navigator.sendBeacon;
        try {
            navigator.sendBeacon = function (url, data) {
                try { push('beacon:' + url, data); } catch (e) { /* */ }
                return real.apply(this, arguments);
            };
        } catch (e) { /* */ }
    }

    // A heartbeat, so an empty report distinguishes "nothing happened" from
    // "the beacons never went out".
    push('alive', 'hooks installed');
    for (const t of [2200, 4000, 8000, 15000, 22000]) setTimeout(report, t);
})()
