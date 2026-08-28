// Reinstalling Navigator.prototype.plugins as a JS accessor that returns the
// real value costs Chrome its cf-scrapingcourse ticket 3 of 3, so the widget
// checks that these accessors are native rather than reading only their values.
// That makes the SHAPE of a native getter -- its source text, its name, its
// arity, its descriptor flags -- a judged surface. This dumps that shape for
// every property the widget was recorded reading, plus the machinery a check
// like it would use.
(() => {
    const rows = {};
    const shape = (o, k) => {
        try {
            const d = Object.getOwnPropertyDescriptor(o, k);
            if (!d) return 'ABSENT';
            const f = d.get || d.value;
            const kind = d.get ? 'get' : (typeof d.value === 'function' ? 'fn' : 'data');
            if (kind === 'data') return 'data enum=' + d.enumerable + ' writable=' + d.writable + ' conf=' + d.configurable;
            return kind + ' name=' + JSON.stringify(f.name) + ' len=' + f.length +
                   ' enum=' + d.enumerable + ' conf=' + d.configurable +
                   ' src=' + JSON.stringify(Function.prototype.toString.call(f));
        } catch (e) { return 'ERR:' + e.name; }
    };
    const NAV = ['plugins', 'mimeTypes', 'userAgent', 'platform', 'language', 'languages', 'onLine',
        'hardwareConcurrency', 'deviceMemory', 'maxTouchPoints', 'webdriver', 'vendor', 'product',
        'appVersion', 'appName', 'cookieEnabled', 'doNotTrack', 'pdfViewerEnabled', 'connection',
        'permissions', 'storage', 'mediaCapabilities', 'keyboard', 'userAgentData', 'gpu',
        'javaEnabled', 'sendBeacon', 'getGamepads', 'getBattery', 'requestMediaKeySystemAccess'];
    for (const k of NAV) rows['Navigator.' + k] = shape(Navigator.prototype, k);
    const WIN = ['devicePixelRatio', 'innerWidth', 'innerHeight', 'outerWidth', 'outerHeight',
        'screenX', 'screenY', 'scrollX', 'scrollY', 'origin', 'isSecureContext', 'crossOriginIsolated',
        'name', 'localStorage', 'sessionStorage', 'indexedDB', 'crypto', 'performance', 'speechSynthesis',
        'visualViewport', 'matchMedia', 'requestIdleCallback', 'queueMicrotask', 'structuredClone',
        'reportError', 'getComputedStyle', 'screen', 'frameElement', 'opener'];
    for (const k of WIN) rows['Window.' + k] = shape(Object.getPrototypeOf(window), k);
    const SCREEN = ['width', 'height', 'availWidth', 'availHeight', 'colorDepth', 'pixelDepth',
        'availLeft', 'availTop', 'isExtended', 'orientation'];
    for (const k of SCREEN) rows['Screen.' + k] = shape(Screen.prototype, k);
    const PERF = ['now', 'timeOrigin', 'getEntries', 'getEntriesByType', 'mark', 'measure'];
    for (const k of PERF) rows['Performance.' + k] = shape(Performance.prototype, k);
    const DOC = ['styleSheets', 'fonts', 'cookie', 'referrer', 'visibilityState', 'hidden', 'characterSet'];
    for (const k of DOC) rows['Document.' + k] = shape(Document.prototype, k);
    const EL = ['getBoundingClientRect', 'attachShadow', 'shadowRoot', 'clientWidth', 'scrollWidth'];
    for (const k of EL) rows['Element.' + k] = shape(Element.prototype, k);
    const HTMLEL = ['offsetWidth', 'offsetHeight', 'offsetParent', 'style'];
    for (const k of HTMLEL) rows['HTMLElement.' + k] = shape(HTMLElement.prototype, k);
    rows['Function.prototype.toString'] = shape(Function.prototype, 'toString');
    rows['toString.toString'] = Function.prototype.toString.call(Function.prototype.toString);
    rows['bound fn src'] = Function.prototype.toString.call(function f() {}.bind(null));
    rows['Proxy of native src'] = (() => {
        try { return Function.prototype.toString.call(new Proxy(navigator.javaEnabled, {})); }
        catch (e) { return 'ERR:' + e.name; }
    })();
    return rows;
})();
