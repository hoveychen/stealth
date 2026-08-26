// Every clock read the guard makes, with the value it got back and where it was
// standing at the time.
//
// probe-clock-calls.js only counted: Date.now 65 vs 54, performance.now 2 vs 2.
// Sixty-five calls is few enough to log all of them, and the counter Akamai
// disagrees with -- the `A` in the `3;0;1;2048;n;<sitekey>;A,...` payload head,
// Chrome 627-698 against this engine's 14-22 -- is small enough to be the
// difference between two of them. So each entry carries the returned value, the
// probe-relative timestamp, the running `charCodeAt` count (which places the
// call on the self-hash timeline), and the top frames of the stack.
//
// XHR open/send land in the same log, because the burn Chrome takes and this
// engine does not sits between the sensor GET and the first POST.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var log = (probe.log = probe.log || []);
    // Held before anything here is wrapped, and used *raw* by `put` below: a
    // timestamp taken through the wrapper recurses until the stack blows.
    var pn = performance.now.bind(performance);
    var dn = Date.now;
    var t0 = pn();
    var cc = 0;
    var LIMIT = 6000;

    var frames = function () {
        try {
            var s = new Error().stack || '';
            var lines = s.split('\n');
            var out = [];
            for (var i = 0; i < lines.length && out.length < 4; i++) {
                var m = /at ([^ (]+)/.exec(lines[i]);
                if (m && m[1] !== 'frames' && !/^Error/.test(m[1])) out.push(m[1]);
            }
            return out.join('<');
        } catch (e) { return '?'; }
    };
    var put = function (kind, value, withStack) {
        if (log.length >= LIMIT) return;
        log.push([Math.round((pn() - t0) * 10) / 10, kind, value, cc,
            withStack ? frames() : '']);
    };

    var ccOrig = String.prototype.charCodeAt;
    String.prototype.charCodeAt = function (i) { cc++; return ccOrig.call(this, i); };

    Date.now = function () { var v = dn(); put('Date.now', v, true); return v; };
    performance.now = function () { var v = pn(); put('perf.now', v, true); return v; };
    var gt = Date.prototype.getTime;
    Date.prototype.getTime = function () { var v = gt.call(this); put('getTime', v, true); return v; };
    var vo = Date.prototype.valueOf;
    Date.prototype.valueOf = function () { var v = vo.call(this); put('valueOf', v, true); return v; };

    var xo = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
        put('open', m + ' ' + String(u).slice(-42), true);
        return xo.apply(this, arguments);
    };
    var xs = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (b) {
        var head = typeof b === 'string' ? b.slice(0, 90) : (b == null ? '' : '[' + typeof b + ']');
        put('send', head, true);
        return xs.apply(this, arguments);
    };

    probe.marks = probe.marks || {};
    probe.ccTotal = function () { return cc; };
})();
