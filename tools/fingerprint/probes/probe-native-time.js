// Which native operation the guard's long function is actually paying for.
//
// The sampling profile says one function of the Akamai sensor holds 650ms of
// *self* time in Chrome and 14ms here. Self time excludes JS callees but
// includes everything native the frame calls, and block coverage shows no hot
// loop inside it -- so the burn is one builtin, handed a big argument. This
// wraps the plausible ones and charges each call to a running total, using a
// clock captured before anything is wrapped so the accounting is not itself
// measured.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var api = (probe.api = probe.api || {});
    var now = performance.now.bind(performance);
    function charge(name, len) {
        var e = api[name] || (api[name] = { n: 0, ms: 0, max: 0 });
        e.n++;
        if (len > e.max) e.max = len;
        return e;
    }
    function wrap(obj, name, key, sizeOf) {
        var fn = obj[name];
        if (typeof fn !== 'function') return;
        obj[name] = function () {
            var e = charge(key, sizeOf ? sizeOf(this, arguments) : 0);
            var t = now();
            try { return fn.apply(this, arguments); }
            finally { e.ms += now() - t; }
        };
    }
    var selfLen = function (t) { return (t && t.length) || 0; };
    var S = String.prototype;
    ['replace', 'replaceAll', 'split', 'match', 'matchAll', 'search', 'indexOf', 'lastIndexOf',
        'slice', 'substring', 'substr', 'concat', 'repeat', 'padStart', 'normalize', 'toLowerCase',
        'toUpperCase', 'trim', 'localeCompare'].forEach(function (m) { wrap(S, m, 'str.' + m, selfLen); });
    ['test', 'exec'].forEach(function (m) {
        wrap(RegExp.prototype, m, 're.' + m, function (_t, a) { return (a[0] && String(a[0]).length) || 0; });
    });
    // Array.prototype and Object are deliberately NOT wrapped: doing so left
    // the page at five nodes with the guard never starting, in both engines.
    wrap(JSON, 'stringify', 'JSON.stringify');
    wrap(JSON, 'parse', 'JSON.parse', function (_t, a) { return (a[0] && a[0].length) || 0; });
    wrap(self, 'btoa', 'btoa', function (_t, a) { return (a[0] && String(a[0]).length) || 0; });
    wrap(self, 'atob', 'atob', function (_t, a) { return (a[0] && String(a[0]).length) || 0; });
    wrap(self, 'encodeURIComponent', 'encodeURIComponent', function (_t, a) { return (a[0] && String(a[0]).length) || 0; });
    wrap(self, 'unescape', 'unescape');
    wrap(Function.prototype, 'toString', 'fn.toString');
    if (self.TextEncoder) wrap(TextEncoder.prototype, 'encode', 'TextEncoder.encode',
        function (_t, a) { return (a[0] && a[0].length) || 0; });
})();
