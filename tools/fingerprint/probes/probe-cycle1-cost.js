// Where the first cycle's milliseconds go -- methods, getters AND constructors.
//
// Two reasons this exists next to probe-device-time.js. First, that probe wraps
// only *methods* on a handful of prototypes, so a cost paid by a getter
// (`navigator.plugins`) or a constructor (`new AudioContext()`) is invisible to
// it. Second, and worse: its totals were read out of `window.__probe` at a long
// settle, and the interstitial reloads itself, so on Chrome that read lands in
// the *second* cycle -- the cheap one, where the counter Akamai receives is 5
// instead of 664. Read this probe at a settle inside cycle one (Chrome ~800ms,
// this engine ~2500ms) or the answer is about the wrong pass.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var api = (probe.api = probe.api || {});
    var now = performance.now.bind(performance);
    var charge = function (key, t) {
        var e = api[key] || (api[key] = { n: 0, ms: 0 });
        e.n++;
        e.ms += now() - t;
    };

    var wrapMethods = function (proto, label) {
        if (!proto) return;
        Object.getOwnPropertyNames(proto).forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || name === 'constructor') return;
            if (typeof d.value === 'function') {
                var fn = d.value;
                try {
                    proto[name] = function () {
                        var t = now();
                        try { return fn.apply(this, arguments); } finally { charge(label + '.' + name, t); }
                    };
                } catch (err) { /* readonly */ }
                return;
            }
            // Getters are the half probe-device-time.js never charged for.
            if (typeof d.get === 'function' && d.configurable) {
                var g = d.get;
                try {
                    Object.defineProperty(proto, name, {
                        configurable: true, enumerable: d.enumerable,
                        set: d.set,
                        get: function () {
                            var t = now();
                            try { return g.call(this); } finally { charge(label + '.get ' + name, t); }
                        },
                    });
                } catch (err) { /* readonly */ }
            }
        });
    };

    // Constructors: `new AudioContext()` and `canvas.getContext('webgl')` are
    // the two shapes where a headless engine returns a stub in microseconds and
    // a real browser wakes a device up.
    var wrapCtor = function (name) {
        var C = self[name];
        if (typeof C !== 'function') return;
        var W = function () {
            var t = now();
            try {
                return new (Function.prototype.bind.apply(C, [null].concat([].slice.call(arguments))))();
            } finally { charge('new ' + name, t); }
        };
        W.prototype = C.prototype;
        try {
            Object.getOwnPropertyNames(C).forEach(function (k) {
                if (k === 'prototype' || k === 'length' || k === 'name' || k === 'arguments' || k === 'caller') return;
                try { W[k] = C[k]; } catch (e) {}
            });
            self[name] = W;
        } catch (e) {}
    };

    [self.Navigator && Navigator.prototype, 'navigator',
        self.Screen && Screen.prototype, 'screen',
        self.Performance && Performance.prototype, 'performance',
        self.Storage && Storage.prototype, 'storage',
        self.WebGLRenderingContext && WebGLRenderingContext.prototype, 'gl',
        self.WebGL2RenderingContext && WebGL2RenderingContext.prototype, 'gl2',
        self.BaseAudioContext && BaseAudioContext.prototype, 'audio',
        self.AudioBuffer && AudioBuffer.prototype, 'audioBuffer',
        self.SubtleCrypto && SubtleCrypto.prototype, 'subtle',
        self.MediaDevices && MediaDevices.prototype, 'mediaDevices',
        self.HTMLCanvasElement && HTMLCanvasElement.prototype, 'canvas',
        self.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, 'ctx2d',
        self.CSSStyleDeclaration && CSSStyleDeclaration.prototype, 'cssStyle',
        self.Element && Element.prototype, 'element',
        self.HTMLElement && HTMLElement.prototype, 'htmlElement',
        self.Document && Document.prototype, 'document',
        self.FontFaceSet && FontFaceSet.prototype, 'fontFaceSet',
        self.Crypto && Crypto.prototype, 'crypto',
        self.PluginArray && PluginArray.prototype, 'pluginArray',
        self.Intl && Intl.DateTimeFormat && Intl.DateTimeFormat.prototype, 'dateTimeFormat',
    ].forEach(function (v, i, a) { if (i % 2 === 0) wrapMethods(v, a[i + 1]); });

    ['AudioContext', 'webkitAudioContext', 'OfflineAudioContext', 'RTCPeerConnection',
        'Worker', 'SharedWorker', 'TextEncoder', 'TextDecoder', 'Image', 'ImageData',
        'OffscreenCanvas', 'MediaStream', 'SpeechSynthesisUtterance', 'Notification',
        'FileReader', 'Blob', 'MutationObserver', 'IntersectionObserver',
        'ResizeObserver', 'WebSocket', 'EventSource', 'BroadcastChannel',
    ].forEach(wrapCtor);

    // Window-level getters that a guard reads and a browser may pay for lazily.
    ['screen', 'navigator', 'localStorage', 'sessionStorage', 'indexedDB', 'speechSynthesis',
        'devicePixelRatio', 'outerWidth', 'outerHeight', 'innerWidth', 'innerHeight',
    ].forEach(function (name) {
        var d;
        try { d = Object.getOwnPropertyDescriptor(self, name); } catch (e) { return; }
        if (!d || typeof d.get !== 'function' || !d.configurable) return;
        var g = d.get;
        try {
            Object.defineProperty(self, name, {
                configurable: true, enumerable: d.enumerable, set: d.set,
                get: function () {
                    var t = now();
                    try { return g.call(this); } finally { charge('window.get ' + name, t); }
                },
            });
        } catch (e) {}
    });
})();
