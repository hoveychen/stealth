// How many times each scheduling primitive actually fires in half a second.
//
// Akamai's macys interstitial reports a number in cleartext at the head of
// sensor_data (field 7, first slot): headed Chrome says ~630, this engine says
// ~16, twice each. Whatever that counter is, a 40x gap in it is the only
// cleartext difference between the two arms on the real site, and the guard's
// own poller is a `setInterval(..., 1)`. So: does a 1ms interval tick at 1ms
// here?
(async () => {
    const over = 500;
    const sample = (start, stop) => new Promise((done) => {
        let n = 0;
        const t0 = performance.now();
        const handle = start(() => n++);
        setTimeout(() => {
            stop(handle);
            done({ n, ms: Math.round(performance.now() - t0) });
        }, over);
    });

    const out = {};
    out.interval1 = await sample((tick) => setInterval(tick, 1), clearInterval);
    out.interval0 = await sample((tick) => setInterval(tick, 0), clearInterval);
    out.interval4 = await sample((tick) => setInterval(tick, 4), clearInterval);
    // A self-rescheduling setTimeout(0) chain, which is the other way a script
    // asks to run as often as the engine will let it.
    out.timeoutChain = await sample((tick) => {
        const state = { on: true };
        const step = () => {
            if (!state.on) return;
            tick();
            setTimeout(step, 0);
        };
        setTimeout(step, 0);
        return state;
    }, (state) => { state.on = false; });
    out.raf = await sample((tick) => {
        const state = { on: true };
        const step = () => {
            if (!state.on) return;
            tick();
            requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
        return state;
    }, (state) => { state.on = false; });

    // The clock the counter would be read off, in case the difference is the
    // clock rather than the scheduler.
    const marks = [];
    for (let i = 0; i < 6; i++) marks.push(performance.now());
    out.nowMarks = marks;
    out.dateNow = Date.now();
    return out;
})()
