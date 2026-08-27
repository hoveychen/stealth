// What the guard answers our `/tl` POST with, on both arms.
//
// The wire says the same thing on each: one XHR to `/tl`, status 200. What
// happens next does not. Chrome navigates the top document again and gets its
// 200; this engine sits on the 429. Two readings can explain that -- the guard
// declined us and said so in the response, or it cleared us and the reload
// never happened here -- and the response body separates them in one run.
//
// So this captures the `/tl` response text (and the response headers, where a
// clearance cookie would be named), and beacons it back through the station's
// own origin, the way inject-b55-funnels.js does: a station run sends no
// Runtime.enable, so there is no console to print to, and antibot-sweep records
// every request URL under --trace.
(() => {
    const rec = [];
    const push = (tag, s) => {
        try { rec.push(tag + '=' + String(s)); } catch (e) { /* */ }
    };

    const X = window.XMLHttpRequest && XMLHttpRequest.prototype;
    if (X) {
        const open = X.open;
        const send = X.send;
        try {
            X.open = function (method, url) {
                try { this.__b83 = String(url); } catch (e) { /* */ }
                return open.apply(this, arguments);
            };
            X.send = function () {
                try {
                    if (this.__b83 && this.__b83.indexOf('/tl') !== -1) {
                        this.addEventListener('load', () => {
                            try {
                                push('tl:status', this.status);
                                push('tl:headers', this.getAllResponseHeaders());
                                push('tl:body', this.responseText);
                            } catch (e) { push('tl:read', e && e.message); }
                            // Immediately, not on the next tick: the passing arm
                            // navigates as soon as it has this answer and takes
                            // every pending timer of the 429 document with it,
                            // which is how the first run of this probe came back
                            // holding only the cleared page's cookies.
                            report();
                        });
                        this.addEventListener('error', () => push('tl:neterror', this.__b83));
                    }
                } catch (e) { /* */ }
                return send.apply(this, arguments);
            };
        } catch (e) { /* */ }
    }

    // Whatever the widget does with the answer: a reload, an assignment to
    // location, a cookie. All three are how a cleared page gets itself served.
    try {
        const desc = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        if (desc && desc.set) {
            Object.defineProperty(document, 'cookie', {
                configurable: true,
                get() { return desc.get.call(document); },
                set(v) { push('cookie', v); return desc.set.call(document, v); },
            });
        }
    } catch (e) { /* */ }
    try {
        const reload = Location.prototype.reload;
        Location.prototype.reload = function () {
            push('nav', 'reload');
            return reload.apply(this, arguments);
        };
        const assign = Location.prototype.assign;
        Location.prototype.assign = function (u) {
            push('nav', 'assign:' + u);
            return assign.apply(this, arguments);
        };
        const replace = Location.prototype.replace;
        Location.prototype.replace = function (u) {
            push('nav', 'replace:' + u);
            return replace.apply(this, arguments);
        };
        // The commonest of the four, and the one the first run of this probe
        // missed: `location.href = x` is a setter, not a method.
        const href = Object.getOwnPropertyDescriptor(Location.prototype, 'href');
        if (href && href.set) {
            Object.defineProperty(Location.prototype, 'href', {
                configurable: true,
                get() { return href.get.call(this); },
                set(v) { push('nav', 'href:' + v); return href.set.call(this, v); },
            });
        }
    } catch (e) { /* */ }

    // A form submit or a synthetic anchor click reaches the same place without
    // touching location at all.
    try {
        const submit = HTMLFormElement.prototype.submit;
        HTMLFormElement.prototype.submit = function () {
            push('nav', 'form:' + this.action);
            return submit.apply(this, arguments);
        };
    } catch (e) { /* */ }

    push('alive', location.href + ' | cookies=' + document.cookie.length);

    const BASE = 'https://www.hyatt.com/__b83t?';
    let sent = 0;
    function report() {
        if (rec.length === sent) return;
        const from = sent;
        sent = rec.length;
        rec.slice(from).forEach((r, k) => {
            const cap = Math.min(r.length, 6000);
            for (let off = 0; off < cap; off += 300) {
                const q = 'i=' + (from + k) + '&o=' + off + '&v=' + encodeURIComponent(r.slice(off, off + 300));
                setTimeout(() => { try { new Image().src = BASE + q; } catch (e) { /* */ } }, 15 * (off / 300 + k * 25));
            }
        });
    }
    // The refused arm can wait; the passing arm navigates away as soon as the
    // guard clears it and takes every pending timer with it, so the first pass
    // has to be early.
    for (const t of [300, 700, 1200, 2000, 3000, 5000, 9000, 16000]) setTimeout(report, t);
})()
