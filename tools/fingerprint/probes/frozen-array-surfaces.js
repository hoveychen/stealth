// Every FrozenArray-returning member this engine has that a page can actually
// reach, asked the one question that separates a FrozenArray from a plain
// `sequence<>`: does it come back frozen. `frozen-array-integrity.js` asks it of
// three members in detail; this one asks it of the whole list, because freezing
// something Chrome leaves extensible is a new tell rather than a closed one.
//
// The answer per row is `frozen|extensible|len` or `absent` / `threw:...`.
(async () => {
    const out = {};
    const look = (key, make) => {
        try {
            const a = make();
            if (a === undefined || a === null) {
                out[key] = 'absent';
                return;
            }
            if (!Array.isArray(a)) {
                out[key] = 'not-an-array:' + Object.prototype.toString.call(a);
                return;
            }
            out[key] = [Object.isFrozen(a), Object.isExtensible(a), a.length].join('|');
        } catch (e) {
            out[key] = 'threw:' + (e && e.name) + ':' + (e && e.message);
        }
    };

    look('navigator.languages', () => navigator.languages);
    look('navigator.userAgentData.brands', () => navigator.userAgentData && navigator.userAgentData.brands);
    look('DataTransfer.types', () => new DataTransfer().types);
    look('ClipboardItem.types', () => new ClipboardItem({ 'text/plain': new Blob(['x']) }).types);
    look('PerformanceObserver.supportedEntryTypes', () => PerformanceObserver.supportedEntryTypes);
    look('navigationTiming.serverTiming', () => performance.getEntriesByType('navigation')[0].serverTiming);
    look('resourceTiming.serverTiming', () => {
        const r = performance.getEntriesByType('resource')[0];
        return r && r.serverTiming;
    });
    look('viewport.segments', () => window.viewport && window.viewport.segments);
    look('input.webkitEntries', () => {
        const i = document.createElement('input');
        i.type = 'file';
        return i.webkitEntries;
    });
    look('MediaMetadata.artwork', () => new MediaMetadata({
        artwork: [{ src: 'http://x/y.png', sizes: '96x96', type: 'image/png' }],
    }).artwork);
    look('MediaMetadata.chapterInfo', () => new MediaMetadata({
        chapterInfo: [{ title: 'a', startTime: 0 }],
    }).chapterInfo);
    look('ChapterInformation.artwork', () => new MediaMetadata({
        chapterInfo: [{ title: 'a', startTime: 0, artwork: [{ src: 'http://x/y.png' }] }],
    }).chapterInfo[0].artwork);
    // Arity 0 and the dictionary is the *first* argument, so a type string
    // there is refused as an init (measured).
    look('ClipboardChangeEvent.types', () => new ClipboardChangeEvent({
        types: ['text/plain'],
    }).types);
    look('CSSViewTransitionRule.types', () => {
        const style = document.createElement('style');
        style.textContent = '@view-transition { navigation: auto; types: a b; }';
        document.head.appendChild(style);
        const rule = style.sheet.cssRules[0];
        return rule && rule.types;
    });
    look('USBIsochronousInTransferResult.packets', () => new USBIsochronousInTransferResult(
        [new USBIsochronousInTransferPacket('ok')],
    ).packets);
    look('USBIsochronousOutTransferResult.packets', () => new USBIsochronousOutTransferResult(
        [new USBIsochronousOutTransferPacket('ok')],
    ).packets);
    look('CookieChangeEvent.changed', () => new CookieChangeEvent('change', {
        changed: [{ name: 'a', value: 'b' }],
    }).changed);
    look('CookieChangeEvent.deleted', () => new CookieChangeEvent('change', {
        deleted: [{ name: 'a', value: 'b' }],
    }).deleted);
    // Needs an await, which is why the whole probe is async (run-expr passes
    // awaitPromise).
    let key = null;
    try {
        key = await crypto.subtle.generateKey(
            { name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt'],
        );
    } catch (e) { out['CryptoKey.usages'] = 'threw:' + (e && e.name); }
    if (key) look('CryptoKey.usages', () => key.usages);
    look('Gamepad.axes', () => {
        const pads = navigator.getGamepads();
        return pads[0] && pads[0].axes;
    });

    // The comparison rows: real `sequence<>` members, which Chrome hands back
    // extensible. If one of these ever reads frozen the rule above is wrong.
    look('performance.getEntries', () => performance.getEntries());
    look('document.getAnimations', () => document.getAnimations());
    look('navigator.plugins[0].length', () => Array.from(navigator.plugins));
    look('element.getClientRects', () => Array.from(document.body.getClientRects()));

    out['secure context'] = String(window.isSecureContext);
    out['origin'] = location.origin;
    return out;
})()
