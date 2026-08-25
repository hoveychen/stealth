// What the guard hands its hash. `MOm(r9h(), 358859)` builds its input as
// `P9h() + kkh() + typeof ...`, where `kkh` is `fmh(`${fn}`, n)` -- a slice of a
// function's own source. Both arms slice a 496251-character string, but that
// says nothing about how much of it survives the slice, and the hash's step
// count is exactly the surviving length. So record the *result* size of every
// string-producing call, not the receiver's.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var out = (probe.calls = probe.calls || {});
    function note(k, len) {
        var e = out[k] || (out[k] = { n: 0, max: 0, sum: 0 });
        e.n++; e.sum += len;
        if (len > e.max) e.max = len;
    }
    ['substr', 'slice', 'substring', 'concat', 'replace', 'trim', 'toLowerCase', 'repeat'].forEach(function (m) {
        var fn = String.prototype[m];
        if (typeof fn !== 'function') return;
        String.prototype[m] = function () {
            var r = fn.apply(this, arguments);
            note('str.' + m, typeof r === 'string' ? r.length : 0);
            return r;
        };
    });
    var ts = Function.prototype.toString;
    Function.prototype.toString = function () { var r = ts.call(this); note('fn.toString', r.length); return r; };
    var join = Array.prototype.join;
    Array.prototype.join = function () { var r = join.apply(this, arguments); note('arr.join', String(r).length); return r; };
})()
