// Is the guard's 650ms of self time layout?
//
// The sensor's long function holds ~650ms in Chrome and 14ms here with the same
// dispatcher path, the same charCodeAt count, and under 2ms total across every
// string/regex/codec builtin (probe-native-time.js). What is left that shows up
// as *self* time in a JS frame is engine work the frame triggers: style
// resolution, layout, text measurement. Chrome pays for those and an engine
// with no real layout does not -- which would explain a 47x gap in a number the
// guard puts in its payload in cleartext.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var api = (probe.api = probe.api || {});
    var now = performance.now.bind(performance);
    function charge(name) { return api[name] || (api[name] = { n: 0, ms: 0 }); }
    function wrapFn(obj, name, key) {
        if (!obj || typeof obj[name] !== 'function') return;
        var fn = obj[name];
        obj[name] = function () {
            var e = charge(key); e.n++;
            var t = now();
            try { return fn.apply(this, arguments); } finally { e.ms += now() - t; }
        };
    }
    function wrapGetter(proto, name, key) {
        if (!proto) return;
        var d = Object.getOwnPropertyDescriptor(proto, name);
        if (!d || !d.get) return;
        var get = d.get;
        Object.defineProperty(proto, name, {
            configurable: true, enumerable: d.enumerable,
            get: function () {
                var e = charge(key); e.n++;
                var t = now();
                try { return get.call(this); } finally { e.ms += now() - t; }
            },
        });
    }
    wrapFn(Element.prototype, 'getBoundingClientRect', 'getBoundingClientRect');
    wrapFn(Element.prototype, 'getClientRects', 'getClientRects');
    wrapFn(self, 'getComputedStyle', 'getComputedStyle');
    wrapFn(Range.prototype, 'getBoundingClientRect', 'range.getBoundingClientRect');
    if (self.CanvasRenderingContext2D) {
        wrapFn(CanvasRenderingContext2D.prototype, 'measureText', 'measureText');
        wrapFn(CanvasRenderingContext2D.prototype, 'getImageData', 'getImageData');
        wrapFn(CanvasRenderingContext2D.prototype, 'fillText', 'fillText');
    }
    if (self.HTMLCanvasElement) {
        wrapFn(HTMLCanvasElement.prototype, 'toDataURL', 'toDataURL');
        wrapFn(HTMLCanvasElement.prototype, 'getContext', 'getContext');
    }
    ['offsetWidth', 'offsetHeight', 'offsetTop', 'offsetLeft'].forEach(function (n) {
        wrapGetter(self.HTMLElement && HTMLElement.prototype, n, n);
    });
    ['clientWidth', 'clientHeight', 'scrollWidth', 'scrollHeight'].forEach(function (n) {
        wrapGetter(Element.prototype, n, n);
    });
    if (self.SVGTextContentElement) wrapFn(SVGTextContentElement.prototype, 'getComputedTextLength', 'getComputedTextLength');
    if (document.fonts) { wrapFn(document.fonts, 'check', 'fonts.check'); wrapFn(document.fonts, 'load', 'fonts.load'); }
    wrapFn(Document.prototype, 'createElement', 'createElement');
    wrapFn(Node.prototype, 'appendChild', 'appendChild');
    wrapFn(Node.prototype, 'removeChild', 'removeChild');
})();
