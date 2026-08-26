// Chrome hashes 496239 characters on its first pass and reports 5 on its second,
// so the result is kept somewhere across reloads, and the sensor reads storage
// 22 times. This records every storage and cookie access with its key and the
// size of the value, in call order, so the two arms' lookups can be compared --
// including whether one of them finds something the other does not.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var log = (probe.marks = probe.marks || []);
    var now = performance.now.bind(performance);
    function wrapStore(store, label) {
        if (!store) return;
        var get = store.getItem.bind(store), set = store.setItem.bind(store), rm = store.removeItem.bind(store);
        try {
            store.getItem = function (k) { var v = get(k); log.push([label + '.get:' + k + '=' + (v === null ? 'null' : v.length), Math.round(now())]); return v; };
            store.setItem = function (k, v) { log.push([label + '.set:' + k + '=' + String(v).length, Math.round(now())]); return set(k, v); };
            store.removeItem = function (k) { log.push([label + '.rm:' + k, Math.round(now())]); return rm(k); };
        } catch (e) { log.push([label + ':unwrappable', 0]); }
    }
    // Storage.prototype, not the instance: an own property on the instance is
    // never reached when the caller goes through the prototype's method, which
    // is what an obfuscated `hN[...]` lookup ends up doing. Wrapping the
    // instance logged nothing in either arm.
    if (self.Storage) {
        var proto = Storage.prototype;
        ['getItem', 'setItem', 'removeItem'].forEach(function (m) {
            var fn = proto[m];
            proto[m] = function (k, v) {
                var r = fn.apply(this, arguments);
                var what = m === 'getItem' ? (r === null ? 'null' : String(r).length) : String(v).length;
                log.push([m + ':' + k + '=' + what, Math.round(now())]);
                return r;
            };
        });
    }
    var d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
    if (d && d.get) {
        Object.defineProperty(document, 'cookie', {
            configurable: true,
            get: function () { var v = d.get.call(document); log.push(['cookie.get[' + v.slice(0, 60) + ']', Math.round(now())]); return v; },
            set: function (v) { log.push(['cookie.set[' + String(v).slice(0, 60) + ']', Math.round(now())]); d.set.call(document, v); },
        });
    }
})()
