// Make the first `navigator.plugins` read cost what Chrome's costs, from JS.
//
// This is a *candidate engine change under test*, not a measurement. What the
// replay established: Akamai's `A` -- the first field after the sitekey in
// `3;0;1;2048;n;<sitekey>;A,B,C,D,E,F` -- is the elapsed milliseconds of the
// first `navigator.plugins` read, measured by the sensor with Date.now() on
// either side (offset 129058, `g5Y`). Chrome pays 627-786ms for it on the
// interstitial and this engine pays 14-22, which is the only plaintext
// disagreement in the whole payload. Reading `navigator.plugins` once at the top
// of the same page drops *Chrome's* own A to 13, so the cost is not a fixed
// property of the browser: it is what that read costs when the guard makes it,
// with the interstitial's 1ms poller already running.
//
// So: burn, do not sleep. The number the sensor ships is a Date.now() delta, and
// a busy loop is the only way to advance the wall clock from inside a getter.
// Charged once per document, because Chrome's is charged once per renderer and
// the interstitial's second cycle reports 5.
(function () {
    var d = Object.getOwnPropertyDescriptor(Navigator.prototype, 'plugins');
    if (!d || typeof d.get !== 'function' || !d.configurable) return;
    var g = d.get;
    var paid = false;
    // The observed range on this machine, sampled per document: a constant
    // would itself be a tell, since no two Chrome loads report the same number.
    var budget = 610 + Math.floor(Math.random() * 90);
    Object.defineProperty(Navigator.prototype, 'plugins', {
        configurable: true, enumerable: d.enumerable,
        get: function () {
            var v = g.call(this);
            if (!paid) {
                paid = true;
                var until = Date.now() + budget;
                var spin = 0;
                while (Date.now() < until) spin++;
            }
            return v;
        },
    });
})();
