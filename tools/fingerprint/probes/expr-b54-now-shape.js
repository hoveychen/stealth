// The shape of the clock, not its value.
//
// Kasada reads `performance.now()` 1083 times on x-hyatt -- more than any other
// member except `window` itself. What comes back here serialises to six
// characters (`2269.5`) and what comes back from Chrome serialises to eighteen
// (`2165.8000000044703`). Both are quantised to the same 100us grid, so the
// difference is not the resolution: Chrome's number carries the float error of
// the arithmetic that produced it and this engine's is an exactly representable
// tenth.
//
// Two things follow and this probe measures both. The lengths differ by about
// twelve bytes per reading, which is what a payload built out of a thousand of
// them would carry. And the *form* is a one-expression tell on its own: a real
// clock almost never lands on a clean tenth, and this one always does.
//
// So: sample the clock hard, and report the distribution of decimal places, the
// distinct gaps between consecutive distinct values, and how many samples are
// exactly representable multiples of the grid. Value-free -- nothing here
// depends on when it ran.
(() => {
    const N = 4000;
    const raw = new Array(N);
    for (let i = 0; i < N; i++) raw[i] = performance.now();

    const strs = raw.map(String);
    const decimals = {};
    let cleanTenth = 0;
    for (const s of strs) {
        const dot = s.indexOf('.');
        const d = dot === -1 ? 0 : s.length - dot - 1;
        decimals[d] = (decimals[d] || 0) + 1;
        if (d <= 1) cleanTenth++;
    }

    // The grid, read off the data rather than assumed: the distinct positive
    // steps between consecutive distinct samples.
    const steps = {};
    let prev = raw[0];
    for (let i = 1; i < N; i++) {
        const d = raw[i] - prev;
        if (d > 0) {
            steps[d.toPrecision(6)] = (steps[d.toPrecision(6)] || 0) + 1;
            prev = raw[i];
        }
    }
    const topSteps = Object.entries(steps).sort((a, b) => b[1] - a[1]).slice(0, 6);

    return {
        samples: N,
        distinctValues: new Set(raw).size,
        // How many characters a payload pays per reading.
        meanLength: (strs.reduce((s, x) => s + x.length, 0) / N).toFixed(3),
        minLength: Math.min(...strs.map((x) => x.length)),
        maxLength: Math.max(...strs.map((x) => x.length)),
        decimalPlaces: decimals,
        // A clock whose every sample is a clean tenth is not a real one.
        cleanTenthFraction: (cleanTenth / N).toFixed(4),
        topSteps: topSteps.map(([v, n]) => v + ' x' + n),
        firstFive: strs.slice(0, 5),
        // timeOrigin and Date share the surface and are worth the same look.
        timeOrigin: String(performance.timeOrigin),
        timeOriginDecimals: String(performance.timeOrigin).split('.')[1]?.length ?? 0,
        dateNowIsInteger: Number.isInteger(Date.now()),
    };
})();
