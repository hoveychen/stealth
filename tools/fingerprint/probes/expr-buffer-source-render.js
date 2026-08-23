// What an OfflineAudioContext renders for AudioBufferSource -> destination.
//
// The Turnstile widget builds three offline contexts per visit. Two are the
// compressor graph canonical_render.zig replays; the third is a bare
// createBuffer -> createBufferSource -> destination with no DSP at all, which
// means its render is arithmetic on the page's own bytes rather than anything
// that had to be recorded off a real machine.
//
// This measures exactly what Chrome does to those bytes: the identity case and
// every knob that could bend it (when/offset/duration, loop, playbackRate,
// detune, an unstarted source, a mismatched buffer rate, more channels than
// the destination has). Run it against both engines and the diff is the answer.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-buffer-source-render.js
(async () => {
    const RATE = 44100;
    const N = 1000;

    // A pattern with no repeats, no zeros and a distinct value per frame, so a
    // shift, a truncation or a repeat all read differently in the digest.
    const fill = (buffer, channels = 1) => {
        for (let c = 0; c < channels; c++) {
            const data = buffer.getChannelData(c);
            for (let i = 0; i < data.length; i++) {
                data[i] = Math.fround((i + 1) / data.length) * (c === 0 ? 1 : -1);
            }
        }
        return buffer;
    };

    // Enough to tell renders apart without shipping 1 000 floats per case.
    const digest = (data) => {
        let sum = 0;
        let nonzero = 0;
        let firstNonzero = -1;
        for (let i = 0; i < data.length; i++) {
            sum += Math.abs(data[i]);
            if (data[i] !== 0) {
                nonzero++;
                if (firstNonzero < 0) firstNonzero = i;
            }
        }
        return {
            length: data.length,
            nonzero,
            firstNonzero,
            sum: sum.toPrecision(12),
            head: [...data.slice(0, 3)],
            tail: [...data.slice(-3)],
        };
    };

    // Renders `frames` of one buffer source, with `tweak` free to move the
    // source, the buffer or the wiring first.
    const render = async (opts = {}) => {
        const {
            frames = N,
            rate = RATE,
            channels = 1,
            bufferChannels = 1,
            bufferFrames = N,
            bufferRate = RATE,
            start = [0],
            tweak = null,
        } = opts;
        const ctx = new OfflineAudioContext(channels, frames, rate);
        const buffer = fill(ctx.createBuffer(bufferChannels, bufferFrames, bufferRate), bufferChannels);
        const src = ctx.createBufferSource();
        src.buffer = buffer;
        src.connect(ctx.destination);
        if (tweak) tweak(src, ctx, buffer);
        if (start !== null) src.start(...start);
        const out = await ctx.startRendering();
        const result = { channel0: digest(out.getChannelData(0)) };
        if (channels > 1) result.channel1 = digest(out.getChannelData(1));
        // The one case worth reporting sample-exactly: is the render the very
        // bytes the page wrote, or merely something that sums the same?
        if (opts.exact) {
            const written = buffer.getChannelData(0);
            const got = out.getChannelData(0);
            let diff = 0;
            let same = 0;
            for (let i = 0; i < Math.min(written.length, got.length); i++) {
                if (got[i] === written[i]) same++;
                diff = Math.max(diff, Math.abs(got[i] - written[i]));
            }
            result.identity = { same, of: written.length, maxDiff: diff };
        }
        return result;
    };

    const cases = {
        // The widget's own graph.
        plain: await render({ start: [0], exact: true }),
        // start() with no arguments at all -- the same thing per spec, worth
        // confirming rather than assuming.
        startNoArgs: await render({ start: [], exact: true }),
        // Never started: Chrome has nothing to play.
        unstarted: await render({ start: null }),
        // Scheduled into the middle of the render.
        whenMid: await render({ start: [500 / RATE] }),
        // Scheduled past the end of it.
        whenLate: await render({ start: [1] }),
        // Skipping the first 100 frames of the buffer.
        offset: await render({ start: [0, 100 / RATE] }),
        // Playing only the first 100 frames of it.
        duration: await render({ start: [0, 0, 100 / RATE] }),
        // A buffer shorter than the render, looped and not.
        shortBuffer: await render({ bufferFrames: 400 }),
        looped: await render({ bufferFrames: 400, tweak: (src) => { src.loop = true; } }),
        // Resampling, both directions.
        rateHalf: await render({ bufferRate: 22050 }),
        rateHigh: await render({ bufferRate: 48000 }),
        // The two k-rate knobs that change the read speed.
        playbackRateHalf: await render({ tweak: (src) => { src.playbackRate.value = 0.5; } }),
        detuned: await render({ tweak: (src) => { src.detune.value = 100; } }),
        // More channels in the buffer than the destination has, and fewer.
        stereoBufferMonoDest: await render({ bufferChannels: 2 }),
        monoBufferStereoDest: await render({ channels: 2 }),
        stereoBufferStereoDest: await render({ channels: 2, bufferChannels: 2 }),
        // No buffer installed at all.
        noBuffer: await render({ tweak: (src) => { src.buffer = null; } }),
        // Two sources summing into the destination.
        doubled: await render({
            exact: true,
            tweak: (src, ctx, buffer) => {
                const other = ctx.createBufferSource();
                other.buffer = buffer;
                other.connect(ctx.destination);
                other.start(0);
            },
        }),
        // Through a gain node rather than straight in.
        throughUnityGain: await render({
            tweak: (src, ctx) => {
                const gain = ctx.createGain();
                src.disconnect(ctx.destination);
                src.connect(gain);
                gain.connect(ctx.destination);
            },
        }),
        // Connected to nothing.
        unwired: await render({ tweak: (src, ctx) => { src.disconnect(ctx.destination); } }),
    };

    return { userAgent: navigator.userAgent, cases };
})()
