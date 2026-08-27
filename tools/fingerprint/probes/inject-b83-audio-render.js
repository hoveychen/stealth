// What the guard's own audio render actually produced, on the live station.
//
// B83 fixed a canonical render that fell through to silence because Kasada
// schedules the oscillator's frequency instead of assigning it. Whether the fix
// reaches the guard is a separate question from whether the door opens, and it
// is the one worth asking first: a change that never fires proves nothing about
// the station either way.
//
// Hooks AudioBuffer.getChannelData -- the last funnel every audio fingerprint
// passes through -- and reports the tail sum, the frame the signal starts at,
// and the graph's own numbers as the page set them. Reporting is by beacon for
// the same reason inject-b55-funnels.js uses one: a station run sends no
// Runtime.enable, so there is no console, and antibot-sweep records every
// request URL under --trace.
(() => {
    const rec = [];

    const AB = window.AudioBuffer && AudioBuffer.prototype;
    if (AB && typeof AB.getChannelData === 'function') {
        const real = AB.getChannelData;
        try {
            Object.defineProperty(AB, 'getChannelData', {
                configurable: true, writable: true, enumerable: false,
                value: function getChannelData(channel) {
                    const data = real.call(this, channel);
                    try {
                        let tail = 0;
                        let all = 0;
                        let first = -1;
                        for (let i = 0; i < data.length; i++) {
                            const m = Math.abs(data[i]);
                            all += m;
                            if (i >= data.length - 500) tail += m;
                            if (first === -1 && data[i] !== 0) first = i;
                        }
                        rec.push([
                            'len:' + data.length,
                            'rate:' + this.sampleRate,
                            'ch:' + this.numberOfChannels,
                            'first:' + first,
                            'tail:' + tail,
                            'all:' + all,
                        ].join(','));
                    } catch (e) { /* */ }
                    return data;
                },
            });
        } catch (e) { /* */ }
    }

    // The parameters as the page left them, captured at the moment it asks to
    // render, so a silent buffer can be told apart from a graph this engine was
    // never going to recognise.
    const hookRender = (proto) => {
        if (!proto || typeof proto.startRendering !== 'function') return;
        const real = proto.startRendering;
        try {
            Object.defineProperty(proto, 'startRendering', {
                configurable: true, writable: true, enumerable: false,
                value: function startRendering() {
                    try { rec.push('render:rate:' + this.sampleRate + ',len:' + this.length); } catch (e) { /* */ }
                    return real.apply(this, arguments);
                },
            });
        } catch (e) { /* */ }
    };
    hookRender(window.OfflineAudioContext && OfflineAudioContext.prototype);

    const hookParam = (name) => {
        const P = window.AudioParam && AudioParam.prototype;
        if (!P || typeof P[name] !== 'function') return;
        const real = P[name];
        try {
            Object.defineProperty(P, name, {
                configurable: true, writable: true, enumerable: false,
                value: function () {
                    try { rec.push(name + ':' + Array.prototype.join.call(arguments, '|')); } catch (e) { /* */ }
                    return real.apply(this, arguments);
                },
            });
        } catch (e) { /* */ }
    };
    hookParam('setValueAtTime');
    hookParam('linearRampToValueAtTime');
    hookParam('exponentialRampToValueAtTime');
    hookParam('setTargetAtTime');
    hookParam('setValueCurveAtTime');

    const BASE = 'https://www.hyatt.com/__b83a?';
    let reported = 0;
    const report = () => {
        if (!rec.length || reported >= rec.length) return;
        reported = rec.length;
        try {
            new Image().src = BASE + 'n=' + rec.length + '&v=' +
                encodeURIComponent(rec.join(';')).slice(0, 1600);
        } catch (e) { /* */ }
    };
    for (const t of [2200, 4000, 8000, 15000]) setTimeout(report, t);
})()
