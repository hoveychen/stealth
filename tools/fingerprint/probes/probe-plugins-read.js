// Every `navigator.plugins` / `navigator.mimeTypes` read, timed one by one.
//
// probe-cycle1-cost.js charged Chrome 632.5ms across 30 `navigator.plugins`
// getter calls in the interstitial's first cycle -- the whole of the 608ms the
// clock trace found inside the sensor's `g5Y`, and the whole of the `A` Akamai
// receives (647 that run). This narrows it: is it one first-touch that pays and
// twenty-nine that ride free, or is every read expensive? The answer decides
// what an engine would have to reproduce.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var reads = (probe.reads = probe.reads || []);
    var pn = performance.now.bind(performance);
    var t0 = pn();

    var frames = function () {
        try {
            var lines = (new Error().stack || '').split('\n');
            var out = [];
            for (var i = 0; i < lines.length && out.length < 3; i++) {
                var m = /at ([^ (]+)/.exec(lines[i]);
                if (m && m[1] !== 'Object.get' && !/^Error/.test(m[1])) out.push(m[1]);
            }
            return out.join('<');
        } catch (e) { return '?'; }
    };

    ['plugins', 'mimeTypes'].forEach(function (name) {
        var d = Object.getOwnPropertyDescriptor(Navigator.prototype, name);
        if (!d || typeof d.get !== 'function' || !d.configurable) {
            reads.push(['missing:' + name, 0, 0, '']);
            return;
        }
        var g = d.get;
        Object.defineProperty(Navigator.prototype, name, {
            configurable: true, enumerable: d.enumerable,
            get: function () {
                var a = pn();
                var v = g.call(this);
                var b = pn();
                if (reads.length < 300) {
                    reads.push([name, Math.round((a - t0) * 10) / 10,
                        Math.round((b - a) * 10) / 10, frames(),
                        v && typeof v.length === 'number' ? v.length : -1]);
                }
                return v;
            },
        });
    });

    // The array is lazy in some engines, so length/item/namedItem can be where
    // the cost really lands.
    if (self.PluginArray) {
        ['item', 'namedItem', 'refresh'].forEach(function (m) {
            var fn = PluginArray.prototype[m];
            if (typeof fn !== 'function') return;
            PluginArray.prototype[m] = function () {
                var a = pn();
                try { return fn.apply(this, arguments); } finally {
                    if (reads.length < 300) reads.push(['PluginArray.' + m,
                        Math.round((a - t0) * 10) / 10, Math.round((pn() - a) * 10) / 10, frames(), -1]);
                }
            };
        });
        var dl = Object.getOwnPropertyDescriptor(PluginArray.prototype, 'length');
        if (dl && typeof dl.get === 'function' && dl.configurable) {
            var gl = dl.get;
            Object.defineProperty(PluginArray.prototype, 'length', {
                configurable: true, enumerable: dl.enumerable,
                get: function () {
                    var a = pn();
                    try { return gl.call(this); } finally {
                        if (reads.length < 300) reads.push(['PluginArray.length',
                            Math.round((a - t0) * 10) / 10, Math.round((pn() - a) * 10) / 10, frames(), -1]);
                    }
                },
            });
        }
    }
})();
