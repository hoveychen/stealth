// What the guard's one long-running function is chewing on. Chrome burns ~650ms
// in it and this engine ~14ms, on the same captured script, with the same
// dispatcher case counts and the same handful of Date.now/Math.random calls --
// so the loop is data-driven, and the data is 40x bigger on one side. These
// wrappers count the per-character work and remember the biggest string each
// one saw, which is enough to say *which* collected value the two arms disagree
// about the size of.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var calls = (probe.calls = probe.calls || {});
    var big = (probe.big = probe.big || {});
    var note = function (k, s) {
        calls[k] = (calls[k] || 0) + 1;
        var len = s && s.length || 0;
        if (len > (big[k] || 0)) big[k] = len;
    };
    var cc = String.prototype.charCodeAt;
    String.prototype.charCodeAt = function (i) { note('charCodeAt', this); return cc.call(this, i); };
    var ca = String.prototype.charAt;
    String.prototype.charAt = function (i) { note('charAt', this); return ca.call(this, i); };
    var fcc = String.fromCharCode;
    String.fromCharCode = function () { calls.fromCharCode = (calls.fromCharCode || 0) + 1; return fcc.apply(String, arguments); };
    var ts = Function.prototype.toString;
    Function.prototype.toString = function () { var r = ts.call(this); note('fn.toString', r); return r; };
    var js = JSON.stringify;
    JSON.stringify = function () { var r = js.apply(JSON, arguments); note('JSON.stringify', r); return r; };
})();
