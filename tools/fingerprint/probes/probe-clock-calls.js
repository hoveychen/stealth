// Counts the primitives a work loop would call, so a 650ms burn in one arm and
// a 14ms burn in the other can be told apart: a loop that runs until a deadline
// reads the clock every iteration, a loop that runs over collected data does
// not read it at all.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var calls = (probe.calls = probe.calls || {});
    var bump = function (k) { calls[k] = (calls[k] || 0) + 1; };
    var dn = Date.now;
    Date.now = function () { bump('Date.now'); return dn.apply(Date, arguments); };
    var pn = performance.now;
    performance.now = function () { bump('performance.now'); return pn.apply(performance, arguments); };
    var mr = Math.random;
    Math.random = function () { bump('Math.random'); return mr.apply(Math, arguments); };
    var gd = Date.prototype.getTime;
    Date.prototype.getTime = function () { bump('getTime'); return gd.apply(this, arguments); };
    var gv = self.crypto && crypto.getRandomValues && crypto.getRandomValues.bind(crypto);
    if (gv) crypto.getRandomValues = function (a) { bump('getRandomValues'); return gv(a); };
})();
