// Which async task each canvas call runs inside, and in what order those tasks
// arrived.
//
// probe-canvas-order.js established that both arms make the same eight
// `getContext` calls with the same receivers and arguments, and complete them in
// a different order -- deterministically, byte-identical within an arm across
// runs. Its stacks cannot say why: the two rows that moved furthest have no
// named frame above the page URL, which is what an async continuation looks
// like. A synchronous stack cannot name the thing that scheduled it.
//
// So this probe records the *task* instead of the frame. Every scheduling
// primitive gets a label at registration (with the site that registered it),
// and while its callback runs that label sits on a stack; a canvas row carries
// whatever is on the stack when it happens. The reordered rows then read as
// "ran inside timer #14, registered from Xyz" rather than as "ran from
// nowhere", and the arms can be diffed on the tasks rather than on the calls.
//
// Both halves live in one probe on purpose. The canvas sequence is the control:
// if wrapping the timers moved the groups around, the group order recorded here
// would not match the signature probe-canvas-order.js reads, and then nothing
// else in the file means anything.
//
// `Function.prototype.toString` is spoofed for the wrappers. The loader's
// tamper check (`expr-loader-native-check.js`) only asks about `fetch` and
// `eval`, which this probe leaves alone, but a wrapper that admits to being a
// wrapper is a branch the real page never sees, and this probe exists to read
// branches.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var tl = (probe.tl = probe.tl || []);          // the merged timeline
    var gc = (probe.gc = probe.gc || []);          // canvas rows, with task + stack
    var TL_LIMIT = 8000;
    var GC_LIMIT = 60;
    try { Error.stackTraceLimit = 60; } catch (e) { /* ignore */ }

    var n = 0;
    // Timings are on the rows here, unlike probe-canvas-order.js, and for a
    // reason that only showed up once the tasks were labelled: the collector
    // that moves is scheduled by a *fixed 1000ms* timer, so how much of the
    // queue an arm drains before that deadline decides the order. That question
    // is about throughput, and there is no way to read throughput off an
    // untimed sequence.
    var t0 = 0;
    try { t0 = performance.now(); } catch (e) { /* ignore */ }
    var now = function () {
        try { return Math.round(performance.now() - t0); } catch (e) { return -1; }
    };
    var log = function (row) {
        if (tl.length >= TL_LIMIT) return -1;
        var i = n++;
        tl.push(i + ' +' + now() + ' ' + row);
        return i;
    };

    // ---- native-looking wrappers -------------------------------------------
    var natives = new WeakSet();
    var mark = function (fn) { try { natives.add(fn); } catch (e) { /* ignore */ } return fn; };
    (function () {
        var ts = Function.prototype.toString;
        var wrapped = function toString() {
            try {
                if (natives.has(this)) {
                    var name = '';
                    try { name = this.name || ''; } catch (e) { /* ignore */ }
                    return 'function ' + name + '() { [native code] }';
                }
            } catch (e) { /* ignore */ }
            return ts.apply(this, arguments);
        };
        mark(wrapped);
        try { Function.prototype.toString = wrapped; } catch (e) { /* ignore */ }
    })();

    // ---- call sites ---------------------------------------------------------
    // Frame 0 is `Error`, frame 1 is the wrapper, frame 2 is the caller. The
    // probe is injected inline, so its own frames carry the document URL and
    // cannot be dropped by name -- the index is the only handle.
    var siteOf = function (stack, want) {
        var lines = String(stack || '').split('\n');
        var out = [];
        for (var i = 2; i < lines.length && out.length < (want || 2); i++) {
            var l = lines[i].trim().replace(/^at\s+/, '')
                .replace(/\(?https?:\/\/[^ )]*\//g, '(');
            if (l) out.push(l.slice(0, 48));
        }
        return out.join('<') || '?';
    };
    var site = function (want) {
        try { return siteOf(new Error().stack, want); } catch (e) { return '?'; }
    };

    // ---- the task stack ----------------------------------------------------
    var stack = [];
    var task = function () { return stack.length ? stack.join('>') : 'sync'; };
    var run = function (label, fn, self_, args) {
        stack.push(label);
        try { return fn.apply(self_, args); } finally { stack.pop(); }
    };

    // ---- timers and frame callbacks ---------------------------------------
    var counters = {};
    var tag = function (kind) {
        counters[kind] = (counters[kind] || 0) + 1;
        return kind + '#' + counters[kind];
    };

    // A scheduler that takes a callback first and returns a handle. `delayed`
    // says whether argument 1 is a delay worth recording -- a rAF timestamp is
    // not a delay, and printing one as if it were reads as a clamp difference
    // that is not there.
    var wrapScheduler = function (owner, name, kind, delayed) {
        var fn;
        try { fn = owner[name]; } catch (e) { return; }
        if (typeof fn !== 'function') return;
        var wrapper = function (cb) {
            if (typeof cb !== 'function') return fn.apply(this, arguments);
            var label = tag(kind);
            var d = delayed ? (arguments.length > 1 ? Number(arguments[1]) || 0 : 0) : null;
            var where = site();
            log(label + ' reg' + (d === null ? '' : ' d=' + d) + ' in=' + task() + ' @' + where);
            var args = [].slice.call(arguments, 1);
            var wrapped = function () {
                log(label + ' fire in=' + task());
                return run(label, cb, this, arguments);
            };
            return fn.apply(this, [wrapped].concat(args));
        };
        mark(wrapper);
        try { owner[name] = wrapper; } catch (e) { /* ignore */ }
    };

    wrapScheduler(self, 'setTimeout', 'T', true);
    wrapScheduler(self, 'setInterval', 'I', true);
    wrapScheduler(self, 'requestAnimationFrame', 'R', false);
    wrapScheduler(self, 'requestIdleCallback', 'D', false);
    wrapScheduler(self, 'queueMicrotask', 'Q', false);

    // `then` is the only handle on a hand-rolled promise chain, and the sensor
    // is a generator driven by one. Awaits inside an async function do not come
    // through here -- they use the internal job -- which is exactly why the
    // promise-returning APIs below are wrapped as well.
    (function () {
        var then = Promise.prototype.then;
        var wrapper = function (onOk, onErr) {
            var label = tag('P');
            var where = site();
            var reg = task();
            var wrap = function (which, cb) {
                if (typeof cb !== 'function') return cb;
                return function () {
                    log(label + ' ' + which + ' in=' + task());
                    return run(label, cb, this, arguments);
                };
            };
            // Registrations are the noisy half: a chain of ten `then`s logs ten
            // rows before anything runs. Only settles are kept unless the
            // registration happened inside a task worth attributing.
            if (reg !== 'sync') log(label + ' then in=' + reg + ' @' + where);
            return then.call(this, wrap('ok', onOk), wrap('no', onErr));
        };
        mark(wrapper);
        try { Promise.prototype.then = wrapper; } catch (e) { /* ignore */ }
    })();

    // ---- promise-returning and callback-taking APIs ------------------------
    // Enumerated rather than generic: wrapping every function on `window` walks
    // into constructors and into `fetch`/`eval`, which the loader checks.
    var wrapAsync = function (owner, name, label) {
        if (!owner) return;
        var fn;
        try { fn = owner[name]; } catch (e) { return; }
        if (typeof fn !== 'function') return;
        var wrapper = function () {
            var id = tag(label || name);
            var shown = [].map.call(arguments, function (a) {
                if (typeof a === 'string') return a.length > 20 ? a.slice(0, 20) + '…' : a;
                if (typeof a === 'number' || typeof a === 'boolean' || a == null) return String(a);
                try { return (a.constructor && a.constructor.name) || 'obj'; } catch (e) { return 'obj'; }
            });
            log(id + ' call(' + shown.join(',') + ') in=' + task() + ' @' + site());
            var out;
            try {
                out = fn.apply(this, arguments);
            } catch (e) {
                log(id + ' throw ' + e);
                throw e;
            }
            if (out && typeof out.then === 'function') {
                try {
                    out.then(function (v) {
                        log(id + ' settle in=' + task());
                        return v;
                    }, function (e) {
                        log(id + ' reject ' + e);
                        throw e;
                    });
                } catch (e) { /* ignore */ }
            }
            return out;
        };
        mark(wrapper);
        try { owner[name] = wrapper; } catch (e) { /* ignore */ }
    };

    var P = function (C) { return C && C.prototype; };
    wrapAsync(self, 'createImageBitmap');
    wrapAsync(P(self.HTMLCanvasElement), 'toBlob');
    wrapAsync(P(self.OffscreenCanvas), 'convertToBlob');
    wrapAsync(P(self.Blob), 'arrayBuffer');
    wrapAsync(P(self.Blob), 'text');
    wrapAsync(P(self.HTMLImageElement), 'decode');
    wrapAsync(P(self.AudioContext) || P(self.webkitAudioContext), 'decodeAudioData');
    wrapAsync(P(self.OfflineAudioContext), 'startRendering');
    wrapAsync(P(self.OfflineAudioContext), 'suspend');
    wrapAsync(P(self.BaseAudioContext), 'decodeAudioData');
    wrapAsync(self.crypto && self.crypto.subtle, 'digest');
    wrapAsync(self.navigator && self.navigator.permissions, 'query');
    wrapAsync(self.navigator && self.navigator.storage, 'estimate');
    wrapAsync(self.navigator && self.navigator.mediaDevices, 'enumerateDevices');
    wrapAsync(self.navigator, 'getBattery');
    wrapAsync(self.navigator, 'requestMediaKeySystemAccess');
    wrapAsync(self.navigator, 'getGamepads');
    wrapAsync(self, 'getComputedStyle');
    wrapAsync(P(self.FontFaceSet) || (self.document && self.document.fonts && Object.getPrototypeOf(self.document.fonts)), 'load');
    wrapAsync(P(self.RTCPeerConnection), 'createOffer');
    wrapAsync(P(self.RTCPeerConnection), 'setLocalDescription');
    wrapAsync(P(self.MessagePort), 'postMessage');
    wrapAsync(P(self.Worker), 'postMessage');
    wrapAsync(P(self.XMLHttpRequest), 'send');
    wrapAsync(P(self.XMLHttpRequest), 'open');
    // `document.fonts.ready` is a promise the sensor can await without ever
    // calling a method, so the getter is the only place to see it.
    (function () {
        var fonts = self.document && self.document.fonts;
        if (!fonts) return;
        var proto = Object.getPrototypeOf(fonts);
        var d;
        try { d = Object.getOwnPropertyDescriptor(proto, 'ready'); } catch (e) { return; }
        if (!d || typeof d.get !== 'function' || !d.configurable) return;
        var g = d.get;
        var getter = function () {
            var id = tag('fontsReady');
            log(id + ' get in=' + task() + ' @' + site());
            var out = g.call(this);
            try {
                out.then(function (v) { log(id + ' settle in=' + task()); return v; });
            } catch (e) { /* ignore */ }
            return out;
        };
        mark(getter);
        try { Object.defineProperty(proto, 'ready', { configurable: true, enumerable: d.enumerable, get: getter, set: d.set }); } catch (e) { /* ignore */ }
    })();

    // ---- listeners ---------------------------------------------------------
    // The two rows with no named frame could equally be an event handler. A
    // listener that was added and then fired is a task like any other.
    (function () {
        var add = EventTarget.prototype.addEventListener;
        var KEEP = { load: 1, message: 1, error: 1, DOMContentLoaded: 1, readystatechange: 1, loadend: 1, canplay: 1, voiceschanged: 1, animationstart: 1, transitionend: 1 };
        var wrapper = function (type, cb) {
            if (!KEEP[type] || typeof cb !== 'function') return add.apply(this, arguments);
            var label = tag('E:' + type);
            var what = 'obj';
            try { what = (this === self ? 'window' : (this.tagName || (this.constructor && this.constructor.name) || 'obj')); } catch (e) { /* ignore */ }
            log(label + ' add on=' + what + ' in=' + task() + ' @' + site());
            var args = [].slice.call(arguments, 2);
            var wrapped = function (ev) {
                log(label + ' fire in=' + task());
                return run(label, cb, this, arguments);
            };
            return add.apply(this, [type, wrapped].concat(args));
        };
        mark(wrapper);
        try { EventTarget.prototype.addEventListener = wrapper; } catch (e) { /* ignore */ }
    })();

    // ---- the control: the canvas sequence ---------------------------------
    var SHORT = {
        HTMLCanvasElement: 'canvas', OffscreenCanvas: 'off',
        CanvasRenderingContext2D: '2d', OffscreenCanvasRenderingContext2D: 'off2d',
        WebGLRenderingContext: 'gl1', WebGL2RenderingContext: 'gl2',
        ImageBitmapRenderingContext: 'bmp',
    };
    var ids = new WeakMap();
    var idOf = function (o) {
        if (!o || (typeof o !== 'object' && typeof o !== 'function')) return null;
        var id;
        try { id = ids.get(o); } catch (e) { return null; }
        if (id) return id;
        var kind;
        try { kind = (o.constructor && o.constructor.name) || 'object'; } catch (e) { kind = 'object'; }
        var short = SHORT[kind];
        if (!short) return null;
        id = tag(short);
        try { ids.set(o, id); } catch (e) { return short + '#?'; }
        return id;
    };
    var wrapGetContext = function (proto) {
        if (!proto) return;
        var fn;
        try { fn = proto.getContext; } catch (e) { return; }
        if (typeof fn !== 'function') return;
        var wrapper = function (kind) {
            var stackText = null;
            try { stackText = new Error().stack; } catch (e) { /* ignore */ }
            var out = fn.apply(this, arguments);
            var recv = idOf(this) || 'this';
            try { recv += '[' + this.width + 'x' + this.height + ']'; } catch (e) { /* ignore */ }
            var i = log('getContext ' + recv + '(' + String(kind) + ')=' + (idOf(out) || String(out)) + ' in=' + task() + ' @' + siteOf(stackText, 3));
            if (gc.length < GC_LIMIT) {
                gc.push(i + ' ' + recv + '(' + String(kind) + ') task=' + task() + ' | '
                    + String(stackText || '').split('\n').slice(1)
                        .map(function (l) { return l.trim().replace(/^at\s+/, '').replace(/\(?https?:\/\/[^ )]*\//g, '('); })
                        .join(' | ').slice(0, 700));
            }
            return out;
        };
        mark(wrapper);
        try { proto.getContext = wrapper; } catch (e) { /* ignore */ }
    };
    wrapGetContext(P(self.HTMLCanvasElement));
    wrapGetContext(P(self.OffscreenCanvas));

    // Frames the sensor builds are part of the ordering question: the group that
    // moved furthest is the one that compares a hidden frame against the top.
    (function () {
        var proto = self.Document && Document.prototype;
        if (!proto) return;
        var fn = proto.createElement;
        var wrapper = function (t) {
            var out = fn.apply(this, arguments);
            var s = String(t).toLowerCase();
            if (s === 'iframe' || s === 'canvas' || s === 'audio' || s === 'video' || s === 'img') {
                log('createElement ' + s + ' in=' + task() + ' @' + site());
            }
            return out;
        };
        mark(wrapper);
        try { proto.createElement = wrapper; } catch (e) { /* ignore */ }
    })();
    (function () {
        var proto = self.Node && Node.prototype;
        if (!proto) return;
        ['appendChild', 'insertBefore', 'removeChild'].forEach(function (name) {
            var fn = proto[name];
            if (typeof fn !== 'function') return;
            var wrapper = function (child) {
                var s = '';
                try { s = String(child && child.tagName || '').toLowerCase(); } catch (e) { /* ignore */ }
                if (s === 'iframe') log(name + ' iframe in=' + task() + ' @' + site());
                return fn.apply(this, arguments);
            };
            mark(wrapper);
            try { proto[name] = wrapper; } catch (e) { /* ignore */ }
        });
    })();
})();
