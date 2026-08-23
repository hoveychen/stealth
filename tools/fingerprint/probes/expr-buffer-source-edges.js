// The edges of the AudioBufferSource render that expr-buffer-source-render.js
// leaves open: how a multi-channel buffer is mixed into a destination with a
// different channel count, whether a `when`/`offset` that lands between two
// frames rounds or interpolates, and what loopStart/loopEnd do to the repeat.
//
// Each case reports the frames themselves rather than a digest, because the
// question here is "which sample landed where", not "how loud was it".
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-buffer-source-edges.js
(async () => {
    const RATE = 44100;

    // Channel c holds (i + 1) * 10^c, so any mix reads back as arithmetic that
    // can only have come from one formula.
    const fill = (buffer) => {
        for (let c = 0; c < buffer.numberOfChannels; c++) {
            const data = buffer.getChannelData(c);
            for (let i = 0; i < data.length; i++) data[i] = (i + 1) * 10 ** c;
        }
        return buffer;
    };

    const render = async (opts) => {
        const {
            frames = 8,
            channels = 1,
            bufferChannels = 1,
            bufferFrames = 8,
            start = [0],
            tweak = null,
        } = opts;
        const ctx = new OfflineAudioContext(channels, frames, RATE);
        const src = ctx.createBufferSource();
        src.buffer = fill(ctx.createBuffer(bufferChannels, bufferFrames, RATE));
        src.connect(ctx.destination);
        if (tweak) tweak(src, ctx);
        if (start !== null) src.start(...start);
        const out = await ctx.startRendering();
        const rows = [];
        for (let c = 0; c < out.numberOfChannels; c++) rows.push([...out.getChannelData(c)]);
        return rows;
    };

    const f = (n) => n / RATE; // frames -> seconds

    return {
        // Down-mix. A 2-channel buffer holding (1..8) and (10..80) into a mono
        // destination: sum says 11, 22, ...; average says 5.5, 11, ...
        stereoToMono: await render({ bufferChannels: 2 }),
        // Three channels into one, which Chrome mixes by a different rule again.
        threeToMono: await render({ bufferChannels: 3 }),
        // Four into one is the other named layout.
        fourToMono: await render({ bufferChannels: 4 }),
        // Up-mix, for the record.
        monoToStereo: await render({ channels: 2 }),
        // And a destination wider than the buffer but not by duplication.
        stereoToQuad: await render({ channels: 4, bufferChannels: 2 }),

        // A start time half a frame in. Rounded to a frame boundary, or is the
        // whole buffer resampled onto the offset grid?
        whenHalfFrame: await render({ start: [f(2.5)] }),
        whenWholeFrame: await render({ start: [f(2)] }),
        // Same question for the read offset.
        offsetHalfFrame: await render({ start: [0, f(2.5)] }),
        offsetWholeFrame: await render({ start: [0, f(2)] }),
        // A duration that is not a whole number of frames.
        durationHalfFrame: await render({ start: [0, 0, f(2.5)] }),

        // An offset at or past the end of the buffer.
        offsetAtEnd: await render({ start: [0, f(8)] }),
        offsetPastEnd: await render({ start: [0, f(20)] }),
        // A duration longer than what is left.
        durationPastEnd: await render({ start: [0, 0, f(99)] }),

        // Looping a 4-frame buffer through an 8-frame render, then the same
        // with the loop confined to a window inside it.
        loopWhole: await render({ bufferFrames: 4, tweak: (s) => { s.loop = true; } }),
        loopWindow: await render({
            bufferFrames: 8,
            tweak: (s) => { s.loop = true; s.loopStart = f(2); s.loopEnd = f(5); },
        }),
        // loopEnd past the end of the buffer, and a backwards window.
        loopEndPastEnd: await render({
            bufferFrames: 4,
            tweak: (s) => { s.loop = true; s.loopEnd = f(99); },
        }),
        loopBackwards: await render({
            bufferFrames: 8,
            tweak: (s) => { s.loop = true; s.loopStart = f(5); s.loopEnd = f(2); },
        }),
        // Looping from an offset inside the loop window.
        loopWithOffset: await render({
            bufferFrames: 8,
            start: [0, f(6)],
            tweak: (s) => { s.loop = true; s.loopStart = f(2); s.loopEnd = f(5); },
        }),
        // A loop window that is not a whole number of frames.
        loopHalfFrame: await render({
            bufferFrames: 8,
            tweak: (s) => { s.loop = true; s.loopStart = f(1); s.loopEnd = f(4.5); },
        }),
        // loop set but with a duration that cuts it short.
        loopWithDuration: await render({
            bufferFrames: 4,
            start: [0, 0, f(6)],
            tweak: (s) => { s.loop = true; },
        }),

        // stop(). The engine records that it happened but not when, and the
        // difference between the two below is the whole reason that matters.
        stopMid: await render({ tweak: (s) => { s.start(0); s.stop(f(3)); }, start: null }),
        stopPastEnd: await render({ tweak: (s) => { s.start(0); s.stop(f(99)); }, start: null }),
        stopNoArgs: await render({ tweak: (s) => { s.start(0); s.stop(); }, start: null }),
        stopHalfFrame: await render({ tweak: (s) => { s.start(0); s.stop(f(3.5)); }, start: null }),
        // stop() before the start it was scheduled for.
        stopBeforeStart: await render({ tweak: (s) => { s.start(f(4)); s.stop(f(2)); }, start: null }),
        // stop() and a duration both cutting the same render.
        stopAndDuration: await render({ tweak: (s) => { s.start(0, 0, f(6)); s.stop(f(3)); }, start: null }),

        // playbackRate of exactly 1 and detune of exactly 0 written explicitly:
        // does touching the param at all change the path Chrome takes?
        explicitUnityRate: await render({ tweak: (s) => { s.playbackRate.value = 1; s.detune.value = 0; } }),
        // A negative playbackRate.
        reversed: await render({ tweak: (s) => { s.playbackRate.value = -1; } }),
        // Rate 2, an exact integer decimation.
        doubleRate: await render({ tweak: (s) => { s.playbackRate.value = 2; } }),
    };
})()
