// The two-arm value capture for the families P1 found the /tl payload actually
// carries, taken on the live station rather than on a stand-in page.
//
// P1 lengthened one family at a time and read `postLen`: computed style values
// carry about 1753 characters, the plugin and mime-type strings about 880,
// element geometry about 499, `canPlayType` about 344, one WebGL renderer
// string about 157, and `toDataURL` nothing at all. This probe records what
// each of those actually answered, so the same families can be diffed between
// the arms and the content shortfall -- 524 characters, measured directly off
// the serialised payload -- attributed to specific answers.
//
// It has to run on x-hyatt itself: the answers depend on the page's own
// elements and stylesheets, and an equivalent probe on a blank page compares
// two engines' defaults rather than two engines' readings of this document.
//
// Every hook records and forwards. Reporting is by beacon, repeatedly, because
// a station run has no console and the passing arm navigates out of the
// document that saw everything.
(() => {
    const seen = new Map();
    const put = (k) => seen.set(k, (seen.get(k) || 0) + 1);

    const wrapCall = (proto, name, fmt) => {
        if (!proto || typeof proto[name] !== 'function') return;
        const real = proto[name];
        try {
            Object.defineProperty(proto, name, {
                configurable: true, writable: true, enumerable: false,
                value: function (...args) {
                    const v = real.apply(this, args);
                    try { put(fmt(args, v, this)); } catch (e) { /* */ }
                    return v;
                },
            });
        } catch (e) { /* */ }
    };

    wrapCall(window.CSSStyleDeclaration && CSSStyleDeclaration.prototype, 'getPropertyValue',
        (a, v) => 'css:' + a[0] + '=' + v);
    wrapCall(window.HTMLMediaElement && HTMLMediaElement.prototype, 'canPlayType',
        (a, v) => 'cpt:' + a[0] + '=' + v);
    wrapCall(window.WebGLRenderingContext && WebGLRenderingContext.prototype, 'getParameter',
        (a, v) => (typeof v === 'string' ? 'gl:' + a[0] + '=' + v : 'gl:' + a[0] + '=#'));
    wrapCall(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype, 'getParameter',
        (a, v) => (typeof v === 'string' ? 'gl2:' + a[0] + '=' + v : 'gl2:' + a[0] + '=#'));

    // Geometry: the value itself, not the element, because the payload carries
    // the number. Distinct values are what matters -- a whole number here where
    // Chrome answers on its 1/64px grid is the shape being hunted.
    const wrapGet = (proto, names, tag) => {
        if (!proto) return;
        for (const name of names) {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.get) continue;
            const get = d.get;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true, enumerable: d.enumerable,
                    get() { const v = get.call(this); try { put(tag + ':' + name + '=' + v); } catch (e) { /* */ } return v; },
                });
            } catch (e) { /* */ }
        }
    };
    wrapGet(window.DOMRectReadOnly && DOMRectReadOnly.prototype, ['width', 'height', 'top', 'left', 'right', 'bottom'], 'rect');
    wrapGet(window.DOMRect && DOMRect.prototype, ['width', 'height', 'top', 'left', 'right', 'bottom'], 'rect');
    wrapGet(window.HTMLElement && HTMLElement.prototype, ['offsetWidth', 'offsetHeight'], 'el');
    wrapGet(window.Element && Element.prototype, ['clientWidth', 'clientHeight'], 'el');
    wrapGet(window.Plugin && Plugin.prototype, ['name', 'description', 'filename'], 'plug');
    wrapGet(window.MimeType && MimeType.prototype, ['type', 'description', 'suffixes'], 'mime');

    const send = (q) => { try { new Image().src = 'https://www.hyatt.com/__b55a?' + q; } catch (e) { /* */ } };
    const sent = new Set();
    let id = 0;
    const flush = () => {
        for (const [k, count] of seen) {
            if (sent.has(k)) continue;
            sent.add(k);
            const line = k + ' x' + count;
            const mine = id++;
            for (let off = 0; off < line.length; off += 300) {
                send('i=' + mine + '&o=' + off + '&v=' + encodeURIComponent(line.slice(off, off + 300)));
            }
        }
    };
    for (const d of [1000, 1600, 2200, 3200, 5000, 9000, 15000]) setTimeout(flush, d);
})();
