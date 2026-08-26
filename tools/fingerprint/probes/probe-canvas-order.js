// The ordered canvas/text call sequence, so the point where the two arms take
// different branches can be read off directly.
//
// probe-cycle1-cost.js counted the same calls the same number of times in both
// arms for every 2D method -- except `measureText`, which Chrome makes 9 times
// and this engine never makes at all. A call the other arm does not make is a
// branch, and a branch is a value we answered differently just before it. This
// logs the sequence with arguments and return shapes so the fork shows up as the
// first row that differs, rather than as a total that does not add up.
//
// Every row is prefixed with the *receiver*, numbered in creation order
// (`canvas#2`, `2d#1`, `gl2#1`), and `getContext` rows carry the call site.
// Without that, four extra `getContext` calls read as "we ask for webgl twice"
// when the question is which canvas asked and from where -- the same sequence
// on a different receiver is a different branch.
//
// Timings are deliberately absent. Akamai's own timing fields turned out to
// span 14..786 across Chrome runs that all passed, so a duration difference is
// not evidence of anything; the call *sequence* is.
(function () {
    var probe = (self.__probe = self.__probe || {});
    var seq = (probe.seq = probe.seq || []);
    // Whole stacks for the `getContext` rows, kept apart from the sequence: the
    // frame that asks for a context says which branch was taken, and the frames
    // under it say which entry point -- a timer, an XHR callback, the parser --
    // got there. An extra call and a reordered call look the same in `seq` and
    // different here.
    var stacks = (probe.gcStacks = probe.gcStacks || []);
    var LIMIT = 1200;
    try { Error.stackTraceLimit = 60; } catch (e) { /* ignore */ }
    // Reading `canvas.width` to label a row would go through the accessor this
    // same probe wraps, so recording has to be single-entry.
    var inside = false;

    var SHORT = {
        HTMLCanvasElement: 'canvas',
        OffscreenCanvas: 'off',
        CanvasRenderingContext2D: '2d',
        OffscreenCanvasRenderingContext2D: 'off2d',
        WebGLRenderingContext: 'gl1',
        WebGL2RenderingContext: 'gl2',
        ImageBitmapRenderingContext: 'bmp',
        CanvasGradient: 'grad',
        CanvasPattern: 'pat',
    };
    var ids = new WeakMap();
    var counters = {};
    var idOf = function (o) {
        if (o === null || (typeof o !== 'object' && typeof o !== 'function')) return null;
        var id;
        try { id = ids.get(o); } catch (e) { return null; }
        if (id) return id;
        var kind;
        try { kind = (o.constructor && o.constructor.name) || 'object'; } catch (e) { kind = 'object'; }
        var short = SHORT[kind];
        if (!short) return null;
        counters[short] = (counters[short] || 0) + 1;
        id = short + '#' + counters[short];
        try { ids.set(o, id); } catch (e) { return short + '#?'; }
        return id;
    };
    // Size belongs on the row, not on the id: the guard resizes canvases
    // between calls and a resize is itself a branch point.
    // A document other than this one handing out this realm's prototypes can be
    // a child frame (a bug) or a document with no browsing context, e.g. one
    // from `createHTMLDocument` or `DOMParser` (correct, same global). Which one
    // it is decides whether there is anything to fix, so record it once.
    var foreign = (probe.foreign = probe.foreign || []);
    var describeForeign = function (doc, el) {
        if (foreign.length > 3) return;
        var d = {};
        // Why a wrapper installed on this realm's prototype fired at all: either
        // the element's own prototype is this realm's, or its chain reaches it.
        try {
            var chain = [], p = Object.getPrototypeOf(el);
            while (p && chain.length < 6) {
                var c = p.constructor && p.constructor.name;
                var top = c && self[c] && self[c].prototype;
                chain.push(c + (top === p ? '=TOP' : '') + (Object.prototype.hasOwnProperty.call(p, 'getContext') ? '+ownGetContext' : ''));
                p = Object.getPrototypeOf(p);
            }
            d.chain = chain.join(' -> ');
            d.getContextIsTopWrapper = el.getContext === self.HTMLCanvasElement.prototype.getContext;
        } catch (e) { d.chain = 'throw ' + e; }
        try { d.url = String(doc.URL); } catch (e) { d.url = 'throw'; }
        try { d.hasView = !!doc.defaultView; } catch (e) { d.hasView = 'throw'; }
        try { d.viewIsSelf = doc.defaultView === self; } catch (e) { d.viewIsSelf = 'throw'; }
        try { d.sameCanvasCtor = !!doc.defaultView && doc.defaultView.HTMLCanvasElement === self.HTMLCanvasElement; } catch (e) { d.sameCanvasCtor = 'throw'; }
        // "Not the same constructor" and "no constructor at all" look identical
        // through a `===`, and they are opposite bugs: a second realm that
        // disagrees, versus a frame that never got a realm.
        try {
            var v = doc.defaultView;
            d.childGlobals = ['HTMLCanvasElement', 'Object', 'Document', 'Window']
                .map(function (n) { return n + ':' + (typeof v[n]) + (v[n] === self[n] ? '=TOP' : ''); }).join(' ');
            d.windowSelfIsWindow = v.self === v;
            d.windowProtoIsTopWindowProto = self.Window && Object.getPrototypeOf(v) === self.Window.prototype;
            d.windowToString = Object.prototype.toString.call(v);
        } catch (e) { d.childGlobals = 'throw ' + e; }
        try { d.frameElement = doc.defaultView && doc.defaultView.frameElement ? doc.defaultView.frameElement.tagName + ' src=' + doc.defaultView.frameElement.getAttribute('src') + ' sandbox=' + doc.defaultView.frameElement.getAttribute('sandbox') : String(doc.defaultView && doc.defaultView.frameElement); } catch (e) { d.frameElement = 'throw'; }
        try { d.docElement = doc.documentElement && doc.documentElement.tagName; } catch (e) { d.docElement = 'throw'; }
        try { d.contentType = doc.contentType; } catch (e) { d.contentType = 'throw'; }
        // Where the frame sits: a grandchild, or a frame whose element belongs
        // to another document, is a different case from a direct child.
        try {
            var w = doc.defaultView;
            d.parentIsSelf = w.parent === self;
            d.topIsSelf = w.top === self;
            d.frameIndex = [].indexOf.call(self.frames, w);
            d.frameElOwnerIsTopDoc = w.frameElement ? w.frameElement.ownerDocument === self.document : 'no-frameElement';
            d.frameElConnected = w.frameElement ? !!w.frameElement.isConnected : 'no-frameElement';
            // Is this the frame's *current* document, or one a navigation or a
            // `document.write` already replaced? A stale document is a
            // different bug from a mis-realmed fresh one.
            d.docIsCurrent = w.document === doc;
            d.docIsContentDocument = w.frameElement ? w.frameElement.contentDocument === doc : 'no-frameElement';
            d.docChildren = doc.documentElement ? doc.documentElement.childElementCount : -1;
            d.docHtmlLen = doc.documentElement ? doc.documentElement.innerHTML.length : -1;
        } catch (e) { d.where2 = 'throw ' + e; }
        try {
        } catch (e) { d.where = 'throw ' + e; }
        foreign.push(d);
    };

    var recv = function (o) {
        var id = idOf(o) || 'this';
        try {
            if (o && typeof o.width === 'number' && typeof o.height === 'number') {
                id += '[' + o.width + 'x' + o.height + ']';
            }
            // The sensor compares a child frame against the top frame, and only
            // the top frame's prototypes are wrapped here. A row for an element
            // some other document owns means that document is handing out this
            // realm's objects -- which is the reading, not a footnote.
            if (o && o.ownerDocument && o.ownerDocument !== self.document) {
                id += '{foreign-doc}';
                describeForeign(o.ownerDocument, o);
            }
            if (o && o.canvas && o.canvas.ownerDocument && o.canvas.ownerDocument !== self.document) id += '{foreign-doc}';
        } catch (e) { /* detached */ }
        return id;
    };

    // `getParameter(37446)` is unreadable and `getParameter(UNMASKED_RENDERER)`
    // is the whole point, so the enum names come off the first live context
    // rather than a hand-written table that would drift.
    var enums = null;
    var enumsFrom = function (gl) {
        if (enums) return;
        enums = {};
        for (var k in gl) {
            try {
                if (typeof gl[k] === 'number' && /^[A-Z][A-Z0-9_]+$/.test(k) && !(gl[k] in enums)) enums[gl[k]] = k;
            } catch (e) { /* ignore */ }
        }
    };

    var brief = function (v) {
        if (typeof v === 'number') return Math.round(v * 100) / 100;
        if (typeof v === 'string') return v.length > 24 ? v.slice(0, 24) + '…' : v;
        if (v === null || v === undefined) return String(v);
        if (typeof v === 'object') {
            if (typeof v.width === 'number' && typeof v.actualBoundingBoxLeft === 'number') {
                return 'TextMetrics(w=' + Math.round(v.width * 100) / 100 + ')';
            }
            var id = idOf(v);
            if (id) return id;
            return (v.constructor && v.constructor.name) || 'object';
        }
        return typeof v;
    };
    // The frame that called the wrapper. The stack has to be taken *in* the
    // wrapper, not here: the probe is injected inline into the document, so its
    // own frames carry the document's URL and cannot be filtered by name.
    // Frame 0 is `Error`, frame 1 is the wrapper itself, frame 2 is the caller.
    var siteOf = function (stack) {
        var lines = String(stack || '').split('\n');
        var out = [];
        for (var i = 2; i < lines.length && out.length < 2; i++) {
            var l = lines[i].trim().replace(/^at\s+/, '');
            if (l) out.push(l.slice(0, 56));
        }
        return out.join(' < ') || '?';
    };

    var record = function (label, args, out, stack) {
        if (seq.length >= LIMIT) return;
        var shown = [].map.call(args, brief);
        if (enums && /\.get(Parameter|Extension|ShaderPrecisionFormat)$/.test(label)) {
            shown = [].map.call(args, function (a) {
                return (typeof a === 'number' && enums[a]) ? enums[a] : brief(a);
            });
        }
        var row = label + '(' + shown.join(',') + ')=' + brief(out);
        if (stack) {
            row += ' @' + siteOf(stack);
            if (stacks.length < 40) {
                stacks.push(seq.length + ' ' + label + ': ' + String(stack).split('\n').slice(1)
                    .map(function (l) { return l.trim().replace(/^at\s+/, '').replace(/\(?http:\/\/127\.0\.0\.1:\d+\//, '('); })
                    .join(' | '));
            }
        }
        seq.push(row);
    };

    var wrapMethods = function (proto, names, sited) {
        if (!proto) return;
        (names || Object.getOwnPropertyNames(proto)).forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || name === 'constructor' || typeof d.value !== 'function') return;
            var fn = d.value;
            var wantSite = !!sited && sited.indexOf(name) !== -1;
            try {
                proto[name] = function () {
                    var stack = wantSite ? new Error().stack : null;
                    var out = fn.apply(this, arguments);
                    if (name === 'getContext' && out && typeof out.getParameter === 'function') enumsFrom(out);
                    if (!inside) {
                        inside = true;
                        try { record(recv(this) + '.' + name, arguments, out, stack); } finally { inside = false; }
                    }
                    return out;
                };
            } catch (e) { /* readonly */ }
        });
    };
    // Accessors matter as much as calls here: `ctx.font = '...'` failing to
    // stick is exactly the kind of answer that would make a guard skip the
    // measureText it would otherwise do.
    var wrapAccessors = function (proto, names) {
        if (!proto) return;
        names.forEach(function (name) {
            var d;
            try { d = Object.getOwnPropertyDescriptor(proto, name); } catch (e) { return; }
            if (!d || typeof d.get !== 'function' || !d.configurable) return;
            var g = d.get, s = d.set;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true, enumerable: d.enumerable,
                    get: function () {
                        var v = g.call(this);
                        if (!inside) {
                            inside = true;
                            try { record(recv(this) + '.get ' + name, [], v); } finally { inside = false; }
                        }
                        return v;
                    },
                    set: function (v) {
                        if (s) s.call(this, v);
                        if (!inside) {
                            inside = true;
                            try { record(recv(this) + '.set ' + name, [v], g.call(this)); } finally { inside = false; }
                        }
                    },
                });
            } catch (e) { /* readonly */ }
        });
    };

    wrapMethods(self.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype);
    wrapAccessors(self.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype,
        ['font', 'fillStyle', 'strokeStyle', 'globalCompositeOperation', 'textBaseline',
            'textAlign', 'lineWidth', 'shadowBlur', 'shadowColor', 'filter', 'letterSpacing']);
    wrapMethods(self.HTMLCanvasElement && HTMLCanvasElement.prototype,
        ['getContext', 'toDataURL', 'toBlob'], ['getContext', 'toDataURL']);
    wrapAccessors(self.HTMLCanvasElement && HTMLCanvasElement.prototype, ['width', 'height']);
    wrapMethods(self.OffscreenCanvas && OffscreenCanvas.prototype,
        ['getContext', 'convertToBlob'], ['getContext']);
    // What the guard does *with* a context says which answer sent it down that
    // branch: an extra `getContext` on its own only says a branch was taken.
    [self.WebGLRenderingContext, self.WebGL2RenderingContext].forEach(function (C) {
        if (!C) return;
        wrapMethods(C.prototype, ['getParameter', 'getExtension', 'getSupportedExtensions',
            'getShaderPrecisionFormat', 'getContextAttributes', 'readPixels', 'createShader',
            'shaderSource', 'compileShader', 'getShaderInfoLog', 'getShaderParameter',
            'createProgram', 'linkProgram', 'getProgramParameter', 'getProgramInfoLog',
            'isContextLost', 'drawArrays', 'drawElements', 'finish', 'flush']);
    });
    // Which realm's `createElement` runs for a document that is not this one.
    // If a child frame's `document` is itself wrapped in this realm, this
    // wrapper fires for it -- and then everything it creates is this realm's
    // too, which is the whole mechanism in one row.
    (function () {
        var proto = self.Document && Document.prototype;
        if (!proto) return;
        var made = (probe.made = probe.made || []);
        var fn = proto.createElement;
        proto.createElement = function (tag) {
            var out = fn.apply(this, arguments);
            try {
                if (made.length < 12 && this !== self.document) {
                    made.push({
                        tag: String(tag),
                        thisProtoIsTop: Object.getPrototypeOf(this) === proto,
                        outProtoIsTop: out && self[out.constructor.name] && Object.getPrototypeOf(out) === self[out.constructor.name].prototype,
                        outCtor: out && out.constructor && out.constructor.name,
                        docUrl: String(this.URL),
                        docChain: (function (o) {
                            var c = [], p = Object.getPrototypeOf(o);
                            while (p && c.length < 6) {
                                var n = p.constructor && p.constructor.name;
                                c.push(n + (n && self[n] && self[n].prototype === p ? '=TOP' : ''));
                                p = Object.getPrototypeOf(p);
                            }
                            return c.join(' -> ');
                        })(this),
                        frames: self.frames.length,
                        iframes: [].map.call(self.document.querySelectorAll('iframe'), function (e) { return e.getAttribute('src'); }).join(','),
                    });
                }
            } catch (e) { /* ignore */ }
            return out;
        };
    })();
    // A control frame of our own on the same page. If the sensor's frame leaks
    // its realm and this one does not, the trigger is something about that
    // frame; if both leak, the trigger is something the page did to all of them.
    var controls = (probe.control = probe.control || []);
    var controlAt = function (tag) {
        (function () {
            var r = { at: tag, docDomain: null };
            try { r.docDomain = String(self.document.domain); } catch (e) { r.docDomain = 'throw'; }
            try {
                var f = self.document.createElement('iframe');
                f.style.display = 'none';
                self.document.body.appendChild(f);
                var w = f.contentWindow;
                var c = w.document.createElement('canvas');
                r.controlCanvasProtoIsTop = Object.getPrototypeOf(c) === self.HTMLCanvasElement.prototype;
                r.controlDocProtoIsTop = Object.getPrototypeOf(w.document) === Object.getPrototypeOf(self.document);
                r.controlCtorIsTop = w.HTMLCanvasElement === self.HTMLCanvasElement;
                f.remove();
            } catch (e) { r.err = String(e); }
            controls.push(r);
        })();
    };
    // Sampled over the page's life: when the answer flips, the trigger is
    // whatever the page did in that window.
    controlAt('inject');
    [100, 300, 600, 1000, 1600, 2400, 3600, 5000].forEach(function (ms) {
        setTimeout(function () { controlAt('t' + ms); }, ms);
    });
    if (self.document && document.fonts) {
        wrapMethods(Object.getPrototypeOf(document.fonts), ['check', 'load']);
    }
})();
