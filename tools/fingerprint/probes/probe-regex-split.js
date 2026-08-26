// What the sensor's `g5Y` feature actually costs, on both sides.
//
// probe-clock-trace.js placed the whole 608ms Chrome burn inside a single
// `Date.now()` bracket in `g5Y` (offset 129058 of the sensor script), whose body
// decodes to:
//
//   var t0 = LF(); var v = H8Y()[<split|replace>](new RegExp(<p>, <f>), <arg>);
//   var t1 = LF(); return { <k>: v, <k2>: t1 - t0 };
//
// -- a value *and its own elapsed milliseconds*, which is why Akamai receives
// 664 from Chrome and 17 from this engine: the number is not a clock skew we
// could fake, it is how long that regex took over whatever `H8Y()` returned.
// So log the regex calls themselves: receiver length, pattern, result shape,
// duration. If `H8Y()` hands Chrome a big string and this engine a small one,
// the difference shows here as an input; if both get the same string, it shows
// as a per-call cost.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var rx = (probe.rx = probe.rx || []);
    var built = (probe.built = probe.built || []);
    var pn = performance.now.bind(performance);
    var LIMIT = 400;

    var describe = function (p) {
        if (p instanceof RegExp) return 're:' + String(p).slice(0, 140);
        return 'str:' + String(p).slice(0, 60);
    };
    var shape = function (v) {
        if (Array.isArray(v)) return 'array[' + v.length + ']';
        if (typeof v === 'string') return 'string[' + v.length + ']';
        return v === null ? 'null' : typeof v;
    };
    var wrap = function (name) {
        var orig = String.prototype[name];
        String.prototype[name] = function () {
            var t0 = pn();
            var out = orig.apply(this, arguments);
            var ms = pn() - t0;
            // Everything cheap and small is noise; keep the calls that could
            // account for hundreds of milliseconds either way.
            if (rx.length < LIMIT && (ms >= 1 || this.length >= 4096)) {
                rx.push([name, this.length, Math.round(ms * 10) / 10,
                    describe(arguments[0]), shape(out), String(this).slice(0, 70)]);
            }
            return out;
        };
    };
    ['split', 'replace', 'replaceAll', 'match', 'matchAll', 'search'].forEach(wrap);

    // Every RegExp the page compiles, in order, so a pattern that never runs is
    // still visible: a source-only difference between the arms would otherwise
    // look like a missing call.
    var RE = self.RegExp;
    var Wrapped = function (p, f) {
        if (built.length < LIMIT) built.push([String(p).slice(0, 160), f === undefined ? '' : String(f)]);
        return new RE(p, f);
    };
    Wrapped.prototype = RE.prototype;
    try {
        Object.getOwnPropertyNames(RE).forEach(function (k) {
            if (k === 'prototype' || k === 'length' || k === 'name') return;
            try { Wrapped[k] = RE[k]; } catch (e) {}
        });
        self.RegExp = Wrapped;
    } catch (e) { probe.reWrapFailed = String(e); }
})();
