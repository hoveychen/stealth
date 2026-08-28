// The widget's first POST is 192 bytes longer on this engine than in Chrome,
// every run, and the two arms read the same 92 property names with the same
// values. So the excess is in something that is not a plain property read: a
// list that serialises longer. These are the lists the read set touches whose
// length is not fixed.
(async () => {
    const out = {};
    const t = (k, f) => { try { out[k] = f(); } catch (e) { out[k] = 'ERR:' + e.name; } };

    t('plugins', () => Array.from(navigator.plugins).map((p) => [p.name, p.filename, p.description,
        Array.from(p).map((m) => [m.type, m.suffixes, m.description])]));
    t('mimeTypes', () => Array.from(navigator.mimeTypes).map((m) => [m.type, m.suffixes, m.description]));
    t('languages', () => navigator.languages);
    t('uaData', () => ({ brands: navigator.userAgentData.brands, mobile: navigator.userAgentData.mobile,
        platform: navigator.userAgentData.platform }));
    out.highEntropy = await navigator.userAgentData.getHighEntropyValues(
        ['architecture', 'bitness', 'model', 'platformVersion', 'uaFullVersion', 'fullVersionList', 'wow64', 'formFactors'])
        .then((v) => v, (e) => 'ERR:' + e.name);
    t('screen', () => {
        const s = {};
        for (const k of ['width', 'height', 'availWidth', 'availHeight', 'availLeft', 'availTop',
            'colorDepth', 'pixelDepth', 'isExtended']) s[k] = screen[k];
        s.orientation = { type: screen.orientation && screen.orientation.type, angle: screen.orientation && screen.orientation.angle };
        return s;
    });
    t('connection', () => {
        const c = navigator.connection;
        return c ? { downlink: c.downlink, effectiveType: c.effectiveType, rtt: c.rtt, saveData: c.saveData } : String(c);
    });
    t('mediaCapabilities', () => Object.getOwnPropertyNames(Object.getPrototypeOf(navigator.mediaCapabilities)));
    t('keyboard', () => String(navigator.keyboard));
    t('storage', () => Object.getOwnPropertyNames(Object.getPrototypeOf(navigator.storage)));
    t('perfMemory', () => performance.memory ? { jsHeapSizeLimit: performance.memory.jsHeapSizeLimit } : String(performance.memory));
    t('visualViewport', () => {
        const v = visualViewport;
        return v ? { width: v.width, height: v.height, scale: v.scale, offsetLeft: v.offsetLeft, offsetTop: v.offsetTop } : String(v);
    });
    t('trustedTypes', () => Object.getOwnPropertyNames(Object.getPrototypeOf(trustedTypes)));
    t('name-origin', () => ({ name: window.name, origin: window.origin, isSecure: isSecureContext,
        crossOriginIsolated, dpr: devicePixelRatio }));

    const lens = {};
    for (const k of Object.keys(out)) lens[k] = JSON.stringify(out[k]).length;
    return { lens, out };
})();
