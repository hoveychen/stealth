// The rest of the search for the guard's 650ms. Everything cheap is ruled out:
// same dispatcher path, same charCodeAt count over the same 496239-char string
// (and both engines run that microbenchmark in 2ms), under 2ms across every
// string/regex/codec builtin, under 10ms across layout and canvas entry points.
// What is left are the device surfaces a headless browser still has to emulate
// -- WebGL, WebAudio, WebCrypto -- so this charges every method on their
// prototypes.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var api = (probe.api = probe.api || {});
    var now = performance.now.bind(performance);
    function wrapAll(proto, label) {
        if (!proto) return;
        Object.getOwnPropertyNames(proto).forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || typeof d.value !== 'function' || name === 'constructor') return;
            var fn = d.value;
            try {
                proto[name] = function () {
                    var key = label + '.' + name;
                    var e = api[key] || (api[key] = { n: 0, ms: 0 });
                    e.n++;
                    var t = now();
                    try { return fn.apply(this, arguments); } finally { e.ms += now() - t; }
                };
            } catch (err) { /* readonly */ }
        });
    }
    wrapAll(self.WebGLRenderingContext && WebGLRenderingContext.prototype, 'gl');
    wrapAll(self.WebGL2RenderingContext && WebGL2RenderingContext.prototype, 'gl2');
    wrapAll(self.BaseAudioContext && BaseAudioContext.prototype, 'audio');
    wrapAll(self.OfflineAudioContext && OfflineAudioContext.prototype, 'offlineAudio');
    wrapAll(self.AudioBuffer && AudioBuffer.prototype, 'audioBuffer');
    wrapAll(self.SubtleCrypto && SubtleCrypto.prototype, 'subtle');
    wrapAll(self.Performance && Performance.prototype, 'performance');
    wrapAll(self.Navigator && Navigator.prototype, 'navigator');
    wrapAll(self.Storage && Storage.prototype, 'storage');
    wrapAll(self.MediaDevices && MediaDevices.prototype, 'mediaDevices');
    wrapAll(self.Intl && Intl.DateTimeFormat && Intl.DateTimeFormat.prototype, 'DateTimeFormat');
})();
