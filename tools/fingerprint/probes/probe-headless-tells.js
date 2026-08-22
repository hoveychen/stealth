// What does `--headless=new` change about a Chrome, holding every other launch
// flag fixed?
//
// This exists because the Cloudflare managed challenge at scrapingcourse
// separates the two: the same Chrome binary, the same profile flags, the same
// address, minutes apart -- headed clears the interstitial and `--headless=new`
// does not (README, "The oracle is headed Chrome"). Whatever the guard is
// reading has to be in the difference between these two runs, so the difference
// is worth having by name rather than by reputation. Most of the folklore list
// ("headless has no plugins", "headless says HeadlessChrome") is about the old
// headless, and `--headless=new` is a real browser with a real renderer; the
// point of measuring is to find which of the claims still hold on this build.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-headless-tells.js \
//        https://example.com/ --headed   > headed.json
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-headless-tells.js \
//        https://example.com/            > headless.json
//   diff <(jq -S . headed.json) <(jq -S . headless.json)
//
// Pass a real https url: several of these (permissions, media devices, the
// secure-context-gated names) answer differently on about:blank.
//
// It reads only, and touches nothing a page would not touch on its own, so the
// same file is safe to run against this engine for a third column.
(async () => {
    const out = {};
    const t = (fn, d) => { try { return fn(); } catch (e) { return d ?? `throw:${e && e.name}`; } };

    out.ua = t(() => navigator.userAgent);
    out.uaHeadlessWord = t(() => /headless/i.test(navigator.userAgent));
    out.appVersion = t(() => navigator.appVersion);
    out.webdriver = t(() => navigator.webdriver);
    out.uaData = t(() => navigator.userAgentData && {
        mobile: navigator.userAgentData.mobile,
        platform: navigator.userAgentData.platform,
        brands: navigator.userAgentData.brands.map((b) => `${b.brand}/${b.version}`).join(','),
    }, null);
    out.uaDataHighEntropy = await t(async () => navigator.userAgentData
        ? await navigator.userAgentData.getHighEntropyValues(
            ['architecture', 'bitness', 'model', 'platformVersion', 'uaFullVersion', 'fullVersionList', 'formFactors', 'wow64'])
        : null, null);

    // --- the window the guard can see --------------------------------------
    out.screen = t(() => ({
        w: screen.width, h: screen.height, aw: screen.availWidth, ah: screen.availHeight,
        al: screen.availLeft, at: screen.availTop, depth: screen.colorDepth, pixelDepth: screen.pixelDepth,
        orientation: screen.orientation && screen.orientation.type,
        isExtended: screen.isExtended,
    }));
    out.window = t(() => ({
        inner: [innerWidth, innerHeight], outer: [outerWidth, outerHeight],
        screenX: window.screenX, screenY: window.screenY, dpr: devicePixelRatio,
    }));
    out.visibility = t(() => ({ state: document.visibilityState, hidden: document.hidden, focus: document.hasFocus() }));

    // --- input capability, which a windowless browser has to answer for ----
    const mq = (q) => t(() => matchMedia(q).matches);
    out.media = {
        hover: mq('(hover: hover)'), anyHover: mq('(any-hover: hover)'),
        pointerFine: mq('(pointer: fine)'), anyPointerFine: mq('(any-pointer: fine)'),
        pointerNone: mq('(pointer: none)'),
        dark: mq('(prefers-color-scheme: dark)'), light: mq('(prefers-color-scheme: light)'),
        reducedMotion: mq('(prefers-reduced-motion: reduce)'),
        forcedColors: mq('(forced-colors: active)'),
        contrastMore: mq('(prefers-contrast: more)'),
        transparency: mq('(prefers-reduced-transparency: reduce)'),
        dynamicRangeHigh: mq('(dynamic-range: high)'),
        monochrome: t(() => matchMedia('(monochrome)').media && matchMedia('(min-monochrome: 1)').matches),
        updateFast: mq('(update: fast)'), scriptingEnabled: mq('(scripting: enabled)'),
    };
    out.maxTouchPoints = t(() => navigator.maxTouchPoints);

    // --- the renderer -------------------------------------------------------
    out.webgl = t(() => {
        const c = document.createElement('canvas');
        const gl = c.getContext('webgl2') || c.getContext('webgl');
        if (!gl) return 'no-context';
        const dbg = gl.getExtension('WEBGL_debug_renderer_info');
        return {
            vendor: gl.getParameter(gl.VENDOR),
            renderer: gl.getParameter(gl.RENDERER),
            unmaskedVendor: dbg && gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL),
            unmaskedRenderer: dbg && gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL),
            version: gl.getParameter(gl.VERSION),
            shading: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
            maxTexture: gl.getParameter(gl.MAX_TEXTURE_SIZE),
            extensions: (gl.getSupportedExtensions() || []).length,
        };
    });
    out.gpuAdapter = await t(async () => {
        if (!navigator.gpu) return null;
        const a = await navigator.gpu.requestAdapter();
        if (!a) return 'no-adapter';
        const i = a.info ?? (a.requestAdapterInfo ? await a.requestAdapterInfo() : null);
        return i ? { vendor: i.vendor, architecture: i.architecture, device: i.device, description: i.description } : 'no-info';
    }, null);
    // A 2D canvas hash separates "same GPU path" from "same API surface": the
    // renderer string can match while the rasteriser does not.
    out.canvas2d = t(() => {
        const c = document.createElement('canvas');
        c.width = 220; c.height = 40;
        const x = c.getContext('2d');
        x.textBaseline = 'top';
        x.font = "14px 'Arial'";
        x.fillStyle = '#f60'; x.fillRect(0, 0, 90, 20);
        x.fillStyle = '#069'; x.fillText('Cwm fjord bank glyphs, \u{1F600}', 2, 15);
        const d = c.toDataURL();
        let h = 0;
        for (let i = 0; i < d.length; i++) { h = (h * 31 + d.charCodeAt(i)) | 0; }
        return { len: d.length, hash: h };
    });

    // --- devices and permissions -------------------------------------------
    out.hardware = t(() => ({
        cores: navigator.hardwareConcurrency, memory: navigator.deviceMemory,
        platform: navigator.platform, languages: (navigator.languages || []).join(','),
        pdfViewerEnabled: navigator.pdfViewerEnabled,
        plugins: navigator.plugins.length, mimeTypes: navigator.mimeTypes.length,
        cookieEnabled: navigator.cookieEnabled, doNotTrack: navigator.doNotTrack,
    }));
    out.mediaDevices = await t(async () => {
        if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return null;
        const ds = await navigator.mediaDevices.enumerateDevices();
        return { count: ds.length, kinds: ds.map((d) => d.kind).join(',') };
    }, null);
    out.notificationPermission = t(() => (typeof Notification !== 'undefined' ? Notification.permission : null));
    out.permissions = await t(async () => {
        const names = ['notifications', 'geolocation', 'camera', 'microphone', 'midi', 'clipboard-read'];
        const r = {};
        for (const n of names) {
            try { r[n] = (await navigator.permissions.query({ name: n })).state; } catch (e) { r[n] = `throw:${e.name}`; }
        }
        return r;
    }, null);
    out.battery = await t(async () => {
        if (!navigator.getBattery) return null;
        const b = await navigator.getBattery();
        return { charging: b.charging, level: b.level, chargingTime: b.chargingTime, dischargingTime: b.dischargingTime };
    }, null);
    out.connection = t(() => navigator.connection && {
        type: navigator.connection.effectiveType, rtt: navigator.connection.rtt,
        downlink: navigator.connection.downlink, saveData: navigator.connection.saveData,
    }, null);
    // Voices arrive asynchronously; one turn of the event loop is enough on a
    // build that has any, and an empty list after that is the finding.
    out.voices = await t(async () => {
        if (!window.speechSynthesis) return null;
        let v = speechSynthesis.getVoices();
        if (!v.length) {
            await new Promise((r) => { speechSynthesis.onvoiceschanged = r; setTimeout(r, 1500); });
            v = speechSynthesis.getVoices();
        }
        return { count: v.length, first: v.slice(0, 3).map((x) => `${x.name}|${x.lang}`).join(',') };
    }, null);

    // --- codecs, fonts, storage --------------------------------------------
    out.codecs = t(() => {
        const v = document.createElement('video'), a = document.createElement('audio');
        return {
            h264: v.canPlayType('video/mp4; codecs="avc1.42E01E"'),
            hevc: v.canPlayType('video/mp4; codecs="hvc1.1.6.L93.B0"'),
            aac: a.canPlayType('audio/mp4; codecs="mp4a.40.2"'),
            webm: v.canPlayType('video/webm; codecs="vp9"'),
            eme: typeof navigator.requestMediaKeySystemAccess === 'function',
        };
    });
    out.widevine = await t(async () => {
        if (!navigator.requestMediaKeySystemAccess) return null;
        try {
            await navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
                initDataTypes: ['cenc'],
                videoCapabilities: [{ contentType: 'video/mp4;codecs="avc1.42E01E"' }],
            }]);
            return 'available';
        } catch (e) { return `rejected:${e.name}`; }
    }, null);
    // Font availability is a rasteriser question, so it moves with the renderer
    // and not with the API surface.
    out.fonts = t(() => {
        const probe = ['Arial', 'Helvetica Neue', 'Times New Roman', 'Courier New', 'Menlo',
            'Apple Color Emoji', 'SF Pro Text', 'Segoe UI', 'Roboto', 'Noto Sans CJK SC'];
        return probe.filter((f) => document.fonts && document.fonts.check(`12px "${f}"`)).join(',');
    });
    out.storage = await t(async () => {
        if (!navigator.storage || !navigator.storage.estimate) return null;
        const e = await navigator.storage.estimate();
        return { quotaGB: Math.round((e.quota / 1e9) * 10) / 10, usage: e.usage };
    }, null);

    out.timing = t(() => ({
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
        offset: new Date().getTimezoneOffset(),
        perfMemory: performance.memory ? Object.keys(performance.memory).length : null,
    }));
    out.chromeObject = t(() => (window.chrome
        ? { keys: Object.keys(window.chrome).sort().join(','), runtime: typeof window.chrome.runtime, loadTimes: typeof window.chrome.loadTimes }
        : null), null);
    out.globalCount = t(() => Object.getOwnPropertyNames(window).length);
    return out;
})()
