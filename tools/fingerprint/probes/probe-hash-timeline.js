// When the per-character work happens, relative to the payload leaving.
//
// Both arms make roughly the same number of charCodeAt calls on the macys
// interstitial (635673 Chrome / 650797 here) but the counter in the payload
// header says 650ms of work on one side and 14ms on the other -- so either the
// work is not what the counter measures, or one arm does it outside the window
// the counter covers. This stamps every 50000th call and every XHR send, which
// is enough to line the two up.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var marks = (probe.marks = probe.marks || []);
    var now = performance.now.bind(performance);
    var n = 0;
    var cc = String.prototype.charCodeAt;
    String.prototype.charCodeAt = function (i) {
        if ((++n % 50000) === 0) marks.push(['chars:' + n, Math.round(now())]);
        return cc.call(this, i);
    };
    var send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
        var head = typeof body === 'string' ? body.slice(0, 60) : String(body).slice(0, 20);
        marks.push(['send:' + (body && body.length) + ':' + head.replace(/[^ -~]/g, '.'), Math.round(now())]);
        return send.apply(this, arguments);
    };
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
        marks.push(['open:' + m + ':' + String(u).slice(-24), Math.round(now())]);
        return open.apply(this, arguments);
    };
    marks.push(['probe', Math.round(now())]);
})()
