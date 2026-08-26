// Causality test for the payload's work counter: can this arm be made to report
// Chrome's number by spending Chrome's time?
//
// The counter is written into the payload when the payload is built, so a delay
// added at `send()` is too late -- the number is already in the body. The window
// it covers runs from the sensor's opening GET to the POST being constructed
// (Chrome: GET at 104ms, POST at 783ms, counter 627-698; here: 248ms, 295ms,
// counter 14-22). So the busy-wait goes at the GET, and it is a *busy* wait on
// purpose: Chrome's 680ms is a blocked main thread, not an idle one, and a
// sleep that yields would let timers run that Chrome's did not.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var marks = (probe.marks = probe.marks || []);
    var burnMs = Number(self.__burnMs || 640);
    var burned = false;
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        var r = open.apply(this, arguments);
        if (!burned && String(method).toUpperCase() === 'GET') {
            burned = true;
            var t0 = Date.now(), spins = 0, sink = 0;
            while (Date.now() - t0 < burnMs) { sink += (spins++ * 2654435761) >>> 0; }
            marks.push(['burned:' + (Date.now() - t0) + 'ms:' + spins, Math.round(performance.now())]);
            probe.burnSink = sink;
        }
        return r;
    };
})()
