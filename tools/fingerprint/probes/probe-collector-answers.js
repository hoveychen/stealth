// What the collector asked, with the arguments it used, and what it was told.
//
// `prop-reads.mjs` (engine-side, invisible to the page) says which members the
// macys collector reaches on this engine: 311 across 71 interfaces. Of those,
// `prop-reads-diff.mjs` can only re-ask the ones reachable from a singleton --
// 104 -- and those now agree with Chrome apart from geometry and the harness's
// own user agent. The other 207 need a receiver or an argument that the read
// log does not record: `canPlayType(what?)`, `matchMedia(which query?)`,
// `getComputedStyle(of which element?)`, `getItem(which key?)`.
//
// So wrap those entry points instead and let the guard supply the arguments.
// Every wrapper forwards unchanged and records `{api, args, answer}` in call
// order, so the two arms can be diffed line by line -- the same method that
// found the shadowColor and script-order bugs, pointed at the non-canvas half
// of the collector.
//
//   node akamai-replay.mjs --bodies <dir> --port N --stall-challenge 120000 \
//        --inject probes/probe-collector-answers.js --quiet
//   LP_BIN=<abs>/zig-out-rel/bin/lightpanda node replay-drive.mjs --arm lp \
//        --url http://127.0.0.1:N/ --settle 6000 --port M --out lp.json
//
// Wrap narrowly. An earlier attempt at "wrap every prototype method" killed the
// page on both arms; these are eleven entry points and a snapshot.
(() => {
    const P = (self.__probe = self.__probe || {});
    const answers = (P.answers = []);
    const t0 = Date.now();
    const at = () => Date.now() - t0;
    const shape = (v) => {
        if (v === null) return 'null';
        const t = typeof v;
        if (t === 'undefined') return 'undefined';
        if (t === 'object') {
            const tag = Object.prototype.toString.call(v);
            return typeof v.length === 'number' ? `${tag}[${v.length}]` : tag;
        }
        if (t === 'function') return `function ${v.name}/${v.length}`;
        if (t === 'string') return v.length > 90 ? `str[${v.length}]:${v.slice(0, 60)}` : JSON.stringify(v);
        return String(v);
    };
    const args = (a) => Array.prototype.map.call(a, (x) => {
        if (x && typeof x === 'object') {
            if (x.nodeName) return `<${String(x.nodeName).toLowerCase()}${x.id ? '#' + x.id : ''}>`;
            return Object.prototype.toString.call(x);
        }
        return shape(x);
    }).join(', ');
    const record = (api, argv, answer) => {
        // The interstitial polls; an unbounded log is a memory leak and a
        // diff nobody can read. Keep the first 40 of each api.
        const key = `n:${api}`;
        P[key] = (P[key] || 0) + 1;
        if (P[key] <= 40) answers.push(`${api}(${argv}) -> ${answer} @${at()}`);
    };

    const wrap = (owner, name, api) => {
        if (!owner || !(name in owner)) return;
        const orig = owner[name];
        if (typeof orig !== 'function') return;
        const patched = function (...a) {
            const r = orig.apply(this, a);
            try { record(api, args(a), shape(r)); } catch { /* never break the page */ }
            return r;
        };
        try {
            Object.defineProperty(patched, 'name', { value: name });
            patched.toString = () => `function ${name}() { [native code] }`;
            owner[name] = patched;
        } catch { /* frozen: leave it */ }
    };

    wrap(self, 'matchMedia', 'matchMedia');
    wrap(self, 'getComputedStyle', 'getComputedStyle');
    if (self.HTMLMediaElement) wrap(self.HTMLMediaElement.prototype, 'canPlayType', 'canPlayType');
    if (self.CSSStyleDeclaration) wrap(self.CSSStyleDeclaration.prototype, 'getPropertyValue', 'getPropertyValue');
    if (self.Storage) {
        wrap(self.Storage.prototype, 'getItem', 'storage.getItem');
        wrap(self.Storage.prototype, 'setItem', 'storage.setItem');
    }
    if (self.CanvasRenderingContext2D) wrap(self.CanvasRenderingContext2D.prototype, 'measureText', 'measureText');
    if (self.SpeechSynthesis) wrap(self.SpeechSynthesis.prototype, 'getVoices', 'getVoices');
    if (self.MediaDevices) wrap(self.MediaDevices.prototype, 'enumerateDevices', 'enumerateDevices');
    if (self.Document) wrap(self.Document.prototype, 'hasFocus', 'hasFocus');
    if (self.Permissions) wrap(self.Permissions.prototype, 'query', 'permissions.query');

    // The values behind the members the collector reads that take no argument
    // and no receiver of its own making. Sampled rather than wrapped: reading
    // them here cannot change what the guard is told, and a snapshot at three
    // points catches a value that only settles later (voices arrive async).
    const snap = () => {
        const s = {};
        const put = (k, f) => { try { s[k] = shape(f()); } catch (e) { s[k] = 'throw: ' + (e && e.message); } };
        const n = navigator;
        put('connection.effectiveType', () => n.connection && n.connection.effectiveType);
        put('connection.rtt', () => n.connection && n.connection.rtt);
        put('connection.downlink', () => n.connection && n.connection.downlink);
        put('connection.saveData', () => n.connection && n.connection.saveData);
        put('connection.type', () => n.connection && n.connection.type);
        put('plugins.length', () => n.plugins.length);
        put('plugins.names', () => Array.prototype.map.call(n.plugins, (p) => `${p.name}|${p.filename}|${p.length}`).join(' ~ '));
        put('mimeTypes.length', () => n.mimeTypes.length);
        put('mimeTypes.names', () => Array.prototype.map.call(n.mimeTypes, (m) => `${m.type}|${m.suffixes}|${m.enabledPlugin && m.enabledPlugin.name}`).join(' ~ '));
        put('voices.length', () => self.speechSynthesis && speechSynthesis.getVoices().length);
        put('memory.limit', () => performance.memory && performance.memory.jsHeapSizeLimit);
        put('memory.total.mod', () => performance.memory && performance.memory.totalJSHeapSize % 4096);
        put('screen.orientation', () => screen.orientation && `${screen.orientation.type}/${screen.orientation.angle}`);
        put('screen.depth', () => `${screen.colorDepth}/${screen.pixelDepth}`);
        put('chrome.keys', () => self.chrome ? Object.keys(self.chrome).sort().join(',') : 'absent');
        put('chrome.runtime', () => self.chrome && typeof self.chrome.runtime);
        put('chrome.loadTimes', () => self.chrome && typeof self.chrome.loadTimes);
        put('fonts.status', () => document.fonts && document.fonts.status);
        put('fonts.size', () => document.fonts && document.fonts.size);
        put('notification.permission', () => self.Notification && Notification.permission);
        put('document.hidden', () => `${document.hidden}/${document.visibilityState}`);
        put('baseURI', () => document.baseURI);
        put('mediaSession', () => navigator.mediaSession && Object.prototype.toString.call(navigator.mediaSession));
        put('storage.persisted', () => typeof (navigator.storage && navigator.storage.persisted));
        put('maxTouchPoints', () => n.maxTouchPoints);
        put('pdfViewerEnabled', () => n.pdfViewerEnabled);
        put('devicePixelRatio', () => devicePixelRatio);
        put('history.length', () => history.length);
        put('crossOriginIsolated', () => self.crossOriginIsolated);
        put('frames.length', () => self.frames.length);
        put('performance.timeOrigin.frac', () => performance.timeOrigin % 1 !== 0);
        return s;
    };
    P.snapAt0 = snap();
    setTimeout(() => { P.snapAt1200 = snap(); }, 1200);
    setTimeout(() => { P.snapAt4000 = snap(); }, 4000);
})();
