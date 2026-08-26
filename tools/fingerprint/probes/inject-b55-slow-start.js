// Is the payload short because this engine collects too early?
//
// The voice-timing probe (inject-b55-voices-time.js) caught Kasada reading
// `speechSynthesis.getVoices()` at 555ms here and at 1400ms in Chrome. Both
// engines take about 700ms to warm that list -- the independent poll returns 0
// at 500ms and 199 at 700ms on *both* arms -- so the empty voice list this
// engine hands the guard is not a missing list. It is a race, lost because this
// engine reaches the guard's collection in a third of the time.
//
// B53 tested the same idea with a Debug build and called it settled: a fifth
// slower to the POST, 853ms against 732ms, same postLen. But a fifth is not
// enough to cross a 665ms threshold that this arm misses by 145ms and Chrome
// clears by 700. This probe moves it far enough to matter.
//
// A busy-wait, not a timer: the point is to delay everything that runs after
// document start, including the guard's own scheduling, the way a slower engine
// would. It is a diagnostic and nothing else -- an 900ms spin is visible in
// every timing the guard takes, so a verdict measured under it is not a verdict
// about the engine.
(() => {
    const SPIN_MS = 900;
    const end = Date.now() + SPIN_MS;
    // Touch a value the optimiser cannot drop, so the loop is not elided.
    let sink = 0;
    while (Date.now() < end) sink += 1;
    try { window.__b55spin = sink; } catch (e) { /* */ }
})();
