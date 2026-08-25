// The ordered canvas/text call sequence, so the point where the two arms take
// different branches can be read off directly.
//
// probe-cycle1-cost.js counted the same calls the same number of times in both
// arms for every 2D method -- except `measureText`, which Chrome makes 9 times
// and this engine never makes at all. A call the other arm does not make is a
// branch, and a branch is a value we answered differently just before it. This
// logs the sequence with arguments and return shapes so the fork shows up as the
// first row that differs, rather than as a total that does not add up.
//
// Timings are deliberately absent. Akamai's own timing fields turned out to
// span 14..786 across Chrome runs that all passed, so a duration difference is
// not evidence of anything; the call *sequence* is.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var seq = (probe.seq = probe.seq || []);
    var LIMIT = 1200;

    var brief = function (v) {
        if (typeof v === 'number') return Math.round(v * 100) / 100;
        if (typeof v === 'string') return v.length > 24 ? v.slice(0, 24) + '…' : v;
        if (v === null || v === undefined) return String(v);
        if (typeof v === 'object') {
            if (typeof v.width === 'number' && typeof v.actualBoundingBoxLeft === 'number') {
                return 'TextMetrics(w=' + Math.round(v.width * 100) / 100 + ')';
            }
            return (v.constructor && v.constructor.name) || 'object';
        }
        return typeof v;
    };
    var record = function (label, args, out) {
        if (seq.length >= LIMIT) return;
        seq.push(label + '(' + [].map.call(args, brief).join(',') + ')=' + brief(out));
    };

    var wrapMethods = function (proto, label, names) {
        if (!proto) return;
        (names || Object.getOwnPropertyNames(proto)).forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || name === 'constructor' || typeof d.value !== 'function') return;
            var fn = d.value;
            try {
                proto[name] = function () {
                    var out = fn.apply(this, arguments);
                    record(label + '.' + name, arguments, out);
                    return out;
                };
            } catch (e) { /* readonly */ }
        });
    };
    // Accessors matter as much as calls here: `ctx.font = '...'` failing to
    // stick is exactly the kind of answer that would make a guard skip the
    // measureText it would otherwise do.
    var wrapAccessors = function (proto, label, names) {
        if (!proto) return;
        names.forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || typeof d.get !== 'function' || !d.configurable) return;
            var g = d.get, s = d.set;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true, enumerable: d.enumerable,
                    get: function () { var v = g.call(this); record(label + '.get ' + name, [], v); return v; },
                    set: function (v) { if (s) s.call(this, v); record(label + '.set ' + name, [v], g.call(this)); },
                });
            } catch (e) { /* readonly */ }
        });
    };

    wrapMethods(self.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, 'ctx');
    wrapAccessors(self.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, 'ctx',
        ['font', 'fillStyle', 'strokeStyle', 'globalCompositeOperation', 'textBaseline',
            'textAlign', 'lineWidth', 'shadowBlur', 'shadowColor', 'filter', 'letterSpacing']);
    wrapMethods(self.HTMLCanvasElement && HTMLCanvasElement.prototype, 'canvas',
        ['getContext', 'toDataURL', 'toBlob']);
    wrapAccessors(self.HTMLCanvasElement && HTMLCanvasElement.prototype, 'canvas', ['width', 'height']);
    wrapMethods(self.OffscreenCanvas && OffscreenCanvas.prototype, 'offscreen', ['getContext', 'convertToBlob']);
    if (self.document && document.fonts) {
        wrapMethods(Object.getPrototypeOf(document.fonts), 'fonts', ['check', 'load']);
    }
})();
