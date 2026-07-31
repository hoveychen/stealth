// Fingerprint surface probe. The whole file is a single async expression so it
// can be handed verbatim to CDP Runtime.evaluate (awaitPromise: true) and to
// Playwright's page.evaluate.
//
// Every read is wrapped: on a partially-implemented engine most of these throw,
// and a probe that dies on the first TypeError tells us nothing. A failed read
// is recorded as {__err: "..."} so "throws" is itself a comparable data point.
(async () => {
    const out = {};
    const get = async (key, fn) => {
        try {
            const v = await fn();
            out[key] = typeof v === 'undefined' ? { __undefined: true } : v;
        } catch (e) {
            out[key] = { __err: String((e && e.message) || e) };
        }
    };
    const names = (o) => {
        try {
            return Object.getOwnPropertyNames(o).sort();
        } catch {
            return null;
        }
    };

    // ---- navigator ----------------------------------------------------------
    for (const k of [
        'userAgent', 'appCodeName', 'appName', 'appVersion', 'platform', 'product',
        'productSub', 'vendor', 'vendorSub', 'oscpu', 'language', 'languages',
        'hardwareConcurrency', 'deviceMemory', 'maxTouchPoints', 'webdriver',
        'pdfViewerEnabled', 'cookieEnabled', 'doNotTrack', 'onLine',
    ]) {
        await get(`navigator.${k}`, () => navigator[k]);
    }
    await get('navigator.ownPropertyNames', () => names(Object.getPrototypeOf(navigator)));
    await get('navigator.plugins.length', () => navigator.plugins.length);
    await get('navigator.plugins.names', () => Array.from(navigator.plugins).map((p) => p.name));
    await get('navigator.mimeTypes.length', () => navigator.mimeTypes.length);
    await get('navigator.userAgentData.brands', () => navigator.userAgentData.brands);
    await get('navigator.userAgentData.mobile', () => navigator.userAgentData.mobile);
    await get('navigator.userAgentData.platform', () => navigator.userAgentData.platform);
    await get('navigator.userAgentData.highEntropy', () =>
        navigator.userAgentData.getHighEntropyValues([
            'architecture', 'bitness', 'model', 'platformVersion', 'uaFullVersion', 'fullVersionList', 'wow64',
        ]));
    await get('navigator.permissions.notifications', async () =>
        (await navigator.permissions.query({ name: 'notifications' })).state);
    await get('navigator.connection', () => ({
        effectiveType: navigator.connection.effectiveType,
        rtt: navigator.connection.rtt,
        downlink: navigator.connection.downlink,
        saveData: navigator.connection.saveData,
    }));
    await get('navigator.mediaDevices', () => typeof navigator.mediaDevices.enumerateDevices);
    await get('navigator.getBattery', () => typeof navigator.getBattery);
    await get('navigator.storage.estimate', async () => typeof (await navigator.storage.estimate()).quota);

    // ---- window.chrome (present in every real Chrome, headless included) -----
    await get('window.chrome', () => typeof window.chrome);
    await get('window.chrome.keys', () => names(window.chrome));
    await get('window.chrome.runtime', () => typeof window.chrome.runtime);
    await get('window.chrome.csi', () => typeof window.chrome.csi);
    await get('window.chrome.loadTimes', () => typeof window.chrome.loadTimes);
    await get('window.chrome.app.isInstalled', () => window.chrome.app.isInstalled);

    // ---- automation tells ---------------------------------------------------
    await get('tell.cdc_props', () => names(window).filter((n) => /^(cdc_|\$cdc|\$chrome_)/.test(n)));
    await get('tell.documentElement.webdriver', () => document.documentElement.getAttribute('webdriver'));
    await get('tell.eval.toString.length', () => eval.toString().length);
    await get('tell.Function.toString.native', () => Function.prototype.toString.call(Function.prototype.toString));
    await get('tell.navigator.toStringTag', () => Object.prototype.toString.call(navigator));
    await get('tell.error.stack.shape', () => {
        try {
            null.f();
        } catch (e) {
            return String(e.stack).split('\n').slice(0, 3).join(' | ');
        }
    });
    await get('tell.Notification.permission', () => Notification.permission);
    await get('tell.outerdim.zero', () => window.outerWidth === 0 || window.outerHeight === 0);

    // ---- screen / window geometry ------------------------------------------
    for (const k of [
        'width', 'height', 'availWidth', 'availHeight', 'availLeft', 'availTop',
        'colorDepth', 'pixelDepth',
    ]) {
        await get(`screen.${k}`, () => screen[k]);
    }
    await get('screen.orientation', () => ({ type: screen.orientation.type, angle: screen.orientation.angle }));
    for (const k of ['innerWidth', 'innerHeight', 'outerWidth', 'outerHeight', 'devicePixelRatio', 'screenX', 'screenY']) {
        await get(`window.${k}`, () => window[k]);
    }
    await get('window.toolbar.visible', () => window.toolbar.visible);

    // ---- locale / timezone --------------------------------------------------
    await get('intl.timeZone', () => Intl.DateTimeFormat().resolvedOptions().timeZone);
    await get('intl.locale', () => Intl.DateTimeFormat().resolvedOptions().locale);
    await get('date.timezoneOffset', () => new Date(0).getTimezoneOffset());
    await get('date.toString', () => new Date(0).toString());

    // ---- canvas 2d ----------------------------------------------------------
    await get('canvas.getContext2d', () => {
        const c = document.createElement('canvas');
        return c.getContext('2d') === null ? null : typeof c.getContext('2d');
    });
    await get('canvas.toDataURL.type', () => typeof document.createElement('canvas').toDataURL);
    await get('canvas.toDataURL.fingerprint', () => {
        const c = document.createElement('canvas');
        c.width = 240;
        c.height = 60;
        const ctx = c.getContext('2d');
        ctx.textBaseline = 'top';
        ctx.font = '14px Arial';
        ctx.fillStyle = '#f60';
        ctx.fillRect(0, 0, 100, 20);
        ctx.fillStyle = '#069';
        ctx.fillText('Cwm fjordbank glyphs vext quiz \u{1F600}', 2, 20);
        const url = c.toDataURL();
        let h = 0;
        for (let i = 0; i < url.length; i++) h = (Math.imul(31, h) + url.charCodeAt(i)) | 0;
        return { len: url.length, prefix: url.slice(0, 30), hash: h };
    });
    await get('canvas.getImageData.nonzero', () => {
        const c = document.createElement('canvas');
        c.width = 10;
        c.height = 10;
        const ctx = c.getContext('2d');
        ctx.fillStyle = '#ff0000';
        ctx.fillRect(0, 0, 10, 10);
        const d = ctx.getImageData(0, 0, 10, 10).data;
        return { first4: [d[0], d[1], d[2], d[3]], anyNonZero: Array.prototype.some.call(d, (x) => x !== 0) };
    });
    await get('canvas.measureText', () => document.createElement('canvas').getContext('2d').measureText('mmmmmmmmmmlli').width);

    // ---- WebGL --------------------------------------------------------------
    for (const kind of ['webgl', 'webgl2', 'experimental-webgl']) {
        await get(`webgl.getContext.${kind}`, () => {
            const gl = document.createElement('canvas').getContext(kind);
            return gl === null ? null : 'ok';
        });
    }
    await get('webgl.params', () => {
        const gl = document.createElement('canvas').getContext('webgl');
        if (!gl) return null;
        const dbg = gl.getExtension('WEBGL_debug_renderer_info');
        return {
            VENDOR: gl.getParameter(gl.VENDOR),
            RENDERER: gl.getParameter(gl.RENDERER),
            VERSION: gl.getParameter(gl.VERSION),
            SHADING_LANGUAGE_VERSION: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
            UNMASKED_VENDOR: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : null,
            UNMASKED_RENDERER: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null,
            MAX_TEXTURE_SIZE: gl.getParameter(gl.MAX_TEXTURE_SIZE),
            extensions: (gl.getSupportedExtensions() || []).length,
        };
    });

    // ---- audio --------------------------------------------------------------
    await get('audio.AudioContext', () => typeof window.AudioContext);
    await get('audio.sampleRate', () => new (window.AudioContext || window.webkitAudioContext)().sampleRate);
    await get('audio.OfflineAudioContext', () => typeof window.OfflineAudioContext);

    // ---- fonts / layout -----------------------------------------------------
    await get('fonts.api', () => typeof document.fonts.check);
    await get('fonts.widths', () => {
        const el = document.createElement('span');
        el.style.cssText = 'position:absolute;left:-9999px;font-size:72px;';
        el.textContent = 'mmmmmmmmmmlli';
        document.body.appendChild(el);
        const r = {};
        for (const f of ['monospace', 'sans-serif', 'serif', 'Arial', 'Helvetica Neue', 'Times New Roman']) {
            el.style.fontFamily = `'${f}'`;
            r[f] = el.offsetWidth;
        }
        el.remove();
        return r;
    });

    // ---- media / misc APIs --------------------------------------------------
    await get('media.canPlayType', () => {
        const v = document.createElement('video');
        return {
            h264: v.canPlayType('video/mp4; codecs="avc1.42E01E"'),
            webm: v.canPlayType('video/webm; codecs="vp8, vorbis"'),
            ogg: v.canPlayType('video/ogg; codecs="theora"'),
        };
    });
    await get('rtc.RTCPeerConnection', () => typeof window.RTCPeerConnection);
    await get('perf.memory', () => (performance.memory ? Object.keys(performance.memory).sort() : null));
    await get('speech.voices.length', () => window.speechSynthesis.getVoices().length);
    await get('matchMedia.dark', () => matchMedia('(prefers-color-scheme: dark)').matches);
    await get('matchMedia.coarsePointer', () => matchMedia('(any-pointer: coarse)').matches);
    await get('matchMedia.hover', () => matchMedia('(any-hover: hover)').matches);
    await get('window.ownPropertyNames.count', () => names(window).length);

    return out;
})()
