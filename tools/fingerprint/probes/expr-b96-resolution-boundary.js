// Where `min-resolution` and `max-resolution` change their mind, to the bit.
//
// x-hyatt's Kasada script reads `devicePixelRatio` eight times and then spends
// 314 `(min|max)-resolution: …)` queries binary-searching the same number to
// twenty bits, reading only `.matches` and never `.media`. B53 caught three
// thresholds in that region where the two arms answer the opposite way round,
// and the plan built on it originally asserted MONOTONICITY -- which was wrong,
// because Chrome is not monotonic there either. So this asks the only question
// that stands: where exactly is each arm's crossover, in each unit.
//
// It bisects the way the guard does rather than sampling a fixed ladder,
// because the crossover is what a fixed ladder is trying to bracket and the
// bisection reports it directly, with the full double on both arms.
(() => {
    const out = {};
    // Asserted in the same run: the whole reading is a claim about
    // devicePixelRatio, so an arm left at a different one is measuring a
    // different question ([[assert-dpr-in-the-same-run]]).
    out.dpr = String(window.devicePixelRatio);
    out.screen = `${screen.width}x${screen.height}`;

    const matches = (feature, value, unit) =>
        matchMedia(`(${feature}: ${value}${unit})`).matches;

    // The largest value that still matches `min-resolution`, and the smallest
    // that still matches `max-resolution`. 200 halvings is well past the last
    // bit of a double, so the loop ends on the exact boundary rather than near
    // it.
    const crossover = (feature, unit, lo, hi) => {
        // `min-resolution` matches below the boundary and stops above it;
        // `max-resolution` is the other way round.
        const matchesLow = matches(feature, lo, unit);
        if (matchesLow === matches(feature, hi, unit)) {
            return `no crossover in [${lo}, ${hi}] (both ${matchesLow})`;
        }
        let a = lo, b = hi;
        for (let i = 0; i < 200; i++) {
            const mid = (a + b) / 2;
            if (mid === a || mid === b) break;
            if (matches(feature, mid, unit) === matchesLow) a = mid; else b = mid;
        }
        return `${a} | ${b}`;
    };

    const dpr = window.devicePixelRatio;
    // One device pixel per CSS pixel is `96dpi`, and a centimetre is 2.54 inches
    // worth of them -- the three spellings of the same quantity, which is the
    // point: a threshold written in one unit has to land where the same
    // threshold written in another does.
    const inUnit = { dppx: dpr, dpi: dpr * 96, dpcm: (dpr * 96) / 2.54 };
    // The bracket is per unit because the tie regions are not the same size:
    // 0.1% either side finds the dppx and dpi crossovers and finds NOTHING in
    // dpcm, where Chrome's conversion is coarse enough that a tenth of a
    // percent is still inside the tie.
    const bracket = { dppx: 0.001, dpi: 0.001, dpcm: 0.05 };
    for (const [unit, exact] of Object.entries(inUnit)) {
        out[`exact ${unit}`] = String(exact);
        const w = bracket[unit];
        out[`min-resolution ${unit}`] = crossover('min-resolution', unit, exact * (1 - w), exact * (1 + w));
        out[`max-resolution ${unit}`] = crossover('max-resolution', unit, exact * (1 - w), exact * (1 + w));
    }

    // The three thresholds B53 measured the two arms disagreeing on, asked
    // verbatim so a fix can be checked against the reading that opened the
    // plan rather than against a recomputed one.
    for (const [feature, value, unit] of [
        ['min-resolution', '1.0000038146972656', 'dppx'],
        ['min-resolution', '1.0000044107437134', 'dppx'],
        ['min-resolution', '37.795257568359375', 'dpcm'],
        ['min-resolution', '1', 'dppx'],
        ['min-resolution', '2', 'dppx'],
        ['min-resolution', '96', 'dpi'],
        ['min-resolution', '192', 'dpi'],
        ['min-resolution', '37.79527559055118', 'dpcm'],
        ['min-resolution', '75.59055118110236', 'dpcm'],
        ['max-resolution', '1', 'dppx'],
        ['max-resolution', '2', 'dppx'],
        ['max-resolution', '96', 'dpi'],
        ['max-resolution', '192', 'dpi'],
    ]) {
        out[`${feature} ${value}${unit}`] = String(matches(feature, value, unit));
    }

    // `<length>` goes through the same serialiser, so the same question is
    // asked of the feature every page reads: where does `min-width` change its
    // mind, against a viewport width that is an integer either way.
    {
        const w = window.innerWidth;
        out['innerWidth'] = String(w);
        out['min-width px'] = crossover('min-width', 'px', w * 0.999, w * 1.001);
        out['max-width px'] = crossover('max-width', 'px', w * 0.999, w * 1.001);
        for (const v of [String(w), String(w + 0.0000001), String(w + 0.000001), String(w + 0.00001), String(w + 0.0001)]) {
            out[`min-width ${v}px`] = String(matches('min-width', v, 'px'));
        }
    }

    // The exact form of the same feature: `min-` and `max-` each tolerate one
    // 1/64 unit, and whether the plain one tolerates it on both sides is a
    // third question, not an implication of the first two.
    {
        const w = window.innerWidth;
        const U = 1 / 64;
        for (const [label, v] of [
            ['exact', w], ['+1/64', w + U], ['+just over', w + U * 1.0001],
            ['-1/64', w - U], ['-just under', w - U * 1.0001],
            ['+half', w + U / 2], ['-half', w - U / 2],
        ]) {
            out[`width ${label} (${v})`] = String(matches('width', v, 'px'));
        }
        out['height exact'] = String(matches('height', window.innerHeight, 'px'));
        out['min-height +1/64'] = String(matches('min-height', window.innerHeight + U, 'px'));
        out['min-height +just over'] = String(matches('min-height', window.innerHeight + U * 1.0001, 'px'));
    }

    // The same quantity in three spellings, at the exact ratio: whatever the
    // rounding is, these three should agree with each other.
    out['agreement at the exact ratio'] = [
        matches('min-resolution', inUnit.dppx, 'dppx'),
        matches('min-resolution', inUnit.dpi, 'dpi'),
        matches('min-resolution', inUnit.dpcm, 'dpcm'),
    ].join(',');

    return out;
})()
