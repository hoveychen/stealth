// The oracle for the `audio_buffer_source_render` block in
// src/browser/tests/audio.html: the same cases, built the same way, rendered by
// whichever engine this is pointed at and printed as the same strings the test
// compares.
//
// The point is that the test's expected values are not inferred from any of the
// other probes -- they are this file's output, case for case, so a claim in the
// test can be re-checked against Chrome in one command rather than argued from
// a neighbouring measurement.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-buffer-source-oracle.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-buffer-source-oracle.js
(async () => {
    const RATE = 44100;
    const f = (n) => n / RATE;

    const fill = (buffer) => {
        for (let c = 0; c < buffer.numberOfChannels; c++) {
            const data = buffer.getChannelData(c);
            for (let i = 0; i < data.length; i++) data[i] = (i + 1) * 10 ** c;
        }
        return buffer;
    };

    const render = async (opts = {}) => {
        const {
            frames = 8, channels = 1, bufferChannels = 1, bufferFrames = 8,
            bufferRate = RATE, start = [0], tweak = null,
        } = opts;
        const ctx = new OfflineAudioContext(channels, frames, RATE);
        const src = ctx.createBufferSource();
        src.buffer = fill(ctx.createBuffer(bufferChannels, bufferFrames, bufferRate));
        src.connect(ctx.destination);
        if (tweak) tweak(src, ctx);
        if (start !== null) src.start(...start);
        const out = await ctx.startRendering();
        const rows = [];
        for (let c = 0; c < out.numberOfChannels; c++) rows.push([...out.getChannelData(c)].join(','));
        return rows.join(' | ');
    };

    const wide = await (async () => {
        const ctx = new OfflineAudioContext(1, 1000, RATE);
        const buffer = ctx.createBuffer(1, 1000, RATE);
        const data = buffer.getChannelData(0);
        for (let i = 0; i < data.length; i++) data[i] = Math.fround((i + 1) / data.length);
        const src = ctx.createBufferSource();
        src.buffer = buffer;
        src.connect(ctx.destination);
        src.start(0);
        const got = (await ctx.startRendering()).getChannelData(0);
        let same = 0;
        for (let i = 0; i < data.length; i++) if (got[i] === data[i]) same++;
        return same;
    })();

    return {
        wide,
        plain: await render({}),
        startNoArgs: await render({ start: [] }),
        whenWholeFrame: await render({ start: [f(2)] }),
        whenLate: await render({ start: [f(99)] }),
        offset: await render({ start: [0, f(2)] }),
        duration: await render({ start: [0, 0, f(3)] }),
        durationPastEnd: await render({ start: [0, 0, f(99)] }),
        offsetAtEnd: await render({ start: [0, f(8)] }),
        shortBuffer: await render({ bufferFrames: 4 }),
        loopWhole: await render({ bufferFrames: 4, tweak: (s) => { s.loop = true; } }),
        loopWindow: await render({ tweak: (s) => { s.loop = true; s.loopStart = f(2); s.loopEnd = f(5); } }),
        loopEndPastEnd: await render({ bufferFrames: 4, tweak: (s) => { s.loop = true; s.loopEnd = f(99); } }),
        loopBackwards: await render({ tweak: (s) => { s.loop = true; s.loopStart = f(5); s.loopEnd = f(2); } }),
        loopWithOffset: await render({
            start: [0, f(6)],
            tweak: (s) => { s.loop = true; s.loopStart = f(2); s.loopEnd = f(5); },
        }),
        loopWithDuration: await render({ bufferFrames: 4, start: [0, 0, f(6)], tweak: (s) => { s.loop = true; } }),
        stopMid: await render({ start: null, tweak: (s) => { s.start(0); s.stop(f(3)); } }),
        stopPastEnd: await render({ start: null, tweak: (s) => { s.start(0); s.stop(f(99)); } }),
        stopNoArgs: await render({ start: null, tweak: (s) => { s.start(0); s.stop(); } }),
        stopBeforeStart: await render({ start: null, tweak: (s) => { s.start(f(4)); s.stop(f(2)); } }),
        explicitUnityRate: await render({ tweak: (s) => { s.playbackRate.value = 1; s.detune.value = 0; } }),
        throughUnityGain: await render({
            tweak: (src, ctx) => {
                const gain = ctx.createGain();
                src.disconnect(ctx.destination);
                src.connect(gain);
                gain.connect(ctx.destination);
            },
        }),
        stereoToStereo: await render({ channels: 2, bufferChannels: 2 }),
        monoToStereo: await render({ channels: 2 }),
        stereoToMono: await render({ bufferChannels: 2 }),

        // The cases this engine answers with silence. Chrome's own value is
        // printed anyway, because a gap is only worth calling a gap once its
        // size is on the record.
        unstarted: await render({ start: null }),
        noBuffer: await render({ tweak: (s) => { s.buffer = null; } }),
        unwired: await render({ tweak: (src, ctx) => { src.disconnect(ctx.destination); } }),
        whenHalfFrame: await render({ start: [f(2.5)] }),
        offsetHalfFrame: await render({ start: [0, f(2.5)] }),
        durationHalfFrame: await render({ start: [0, 0, f(2.5)] }),
        loopHalfFrame: await render({ tweak: (s) => { s.loop = true; s.loopStart = f(1); s.loopEnd = f(4.5); } }),
        stopHalfFrame: await render({ start: null, tweak: (s) => { s.start(0); s.stop(f(3.5)); } }),
        bufferRateLow: await render({ bufferRate: 22050 }),
        bufferRateHigh: await render({ bufferRate: 48000 }),
        playbackRateHalf: await render({ tweak: (s) => { s.playbackRate.value = 0.5; } }),
        playbackRateDouble: await render({ tweak: (s) => { s.playbackRate.value = 2; } }),
        reversed: await render({ tweak: (s) => { s.playbackRate.value = -1; } }),
        detuned: await render({ tweak: (s) => { s.detune.value = 100; } }),
        doubled: await render({
            tweak: (src, ctx) => {
                const other = ctx.createBufferSource();
                other.buffer = src.buffer;
                other.connect(ctx.destination);
                other.start(0);
            },
        }),
        throughHalfGain: await render({
            tweak: (src, ctx) => {
                const gain = ctx.createGain();
                gain.gain.value = 0.5;
                src.disconnect(ctx.destination);
                src.connect(gain);
                gain.connect(ctx.destination);
            },
        }),
        threeToMono: await render({ bufferChannels: 3 }),
        modulated: await render({
            tweak: (src, ctx) => {
                const lfo = ctx.createOscillator();
                lfo.connect(src.playbackRate);
                lfo.start(0);
            },
        }),
    };
})()
