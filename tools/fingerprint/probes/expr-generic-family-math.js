// What each CSS generic family actually measures as, in one page.
//
// `font_metrics.zig` has a table for serif, sans-serif, monospace, cursive,
// fantasy and system-ui. Everything else in the CSS Fonts 4 generic list --
// `math`, `fangsong`, `ui-serif`, `ui-sans-serif`, `ui-monospace`,
// `ui-rounded`, `emoji` -- falls through to the standard fallback, which is
// only right if Chrome resolves them to the same face.
//
// A width alone cannot say whether two names are the same face, so this reports
// three things per family: the advance sum of a pangram, the advance of the
// digit `0` (the `ch` unit), and the ink ascent of `x` (the `ex` unit). Two
// names that agree on all three at 100px are the same table for our purposes;
// one that differs on any of them needs its own.
(() => {
    const NAMES = [
        'serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui',
        'math', 'fangsong', 'ui-serif', 'ui-sans-serif', 'ui-monospace',
        'ui-rounded', 'emoji',
        // Controls: a name nothing supplies, and one the host really has.
        'NoSuchFamilyAtAll', 'Courier New',
    ];
    const host = document.createElement('div');
    host.style.cssText = 'position:absolute;left:-9999px;top:0';
    document.body.appendChild(host);

    const measure = (family) => {
        const span = document.createElement('span');
        span.style.cssText = 'font-size:100px;white-space:pre';
        span.style.fontFamily = family;
        span.textContent = 'Hamburgefonstiv 0123';
        host.appendChild(span);
        const width = span.getBoundingClientRect().width;
        // ch and ex come from the computed style, which is the pair a guard
        // reads for those units.
        const probe = document.createElement('div');
        probe.style.cssText = 'font-size:100px;width:1ch;height:1ex';
        probe.style.fontFamily = family;
        host.appendChild(probe);
        const cs = getComputedStyle(probe);
        const out = { width, ch: cs.width, ex: cs.height, family: getComputedStyle(span).fontFamily };
        span.remove();
        probe.remove();
        return out;
    };

    const out = {};
    for (const n of NAMES) {
        try { out[n] = measure(n); } catch (e) { out[n] = 'throw:' + e.message; }
    }
    host.remove();
    return out;
})()
