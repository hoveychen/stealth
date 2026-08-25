// What `PerformanceObserver.supportedEntryTypes` actually advertises, and
// whether advertising a type implies anything else observable: an interface
// object on the window, an `observe` that accepts it, a non-empty buffer.
//
// The list is read directly by fingerprinters -- it is one string per entry
// type, ordered, and it changes between Chrome versions -- so being two names
// short of the running browser is a version tell on its own.
(() => {
    const out = {};
    out.supported = PerformanceObserver.supportedEntryTypes.join(',');
    out.count = PerformanceObserver.supportedEntryTypes.length;

    // Advertising a type does not require an interface object: Chrome 151 has
    // InteractionContentfulPaint on the window and nothing named for
    // soft-navigation, yet advertises both types.
    for (const name of [
        'SoftNavigationEntry', 'PerformanceSoftNavigation', 'InteractionContentfulPaint',
        'PerformanceLongAnimationFrameTiming', 'PerformanceScriptTiming',
    ]) {
        out['typeof ' + name] = typeof window[name];
    }

    // And `observe` refuses nothing -- an unknown type is a console warning,
    // not a throw, so the list is not enforced anywhere a page can see.
    const tryObserve = (init) => {
        try {
            new PerformanceObserver(() => { }).observe(init);
            return 'ok';
        } catch (e) {
            return (e && e.name) + ': ' + (e && e.message);
        }
    };
    out['observe {type: soft-navigation}'] = tryObserve({ type: 'soft-navigation', buffered: true });
    out['observe {type: interaction-contentful-paint}'] =
        tryObserve({ type: 'interaction-contentful-paint', buffered: true });
    out['observe {type: bogus}'] = tryObserve({ type: 'bogus-nothing' });
    out['observe {entryTypes: [bogus]}'] = tryObserve({ entryTypes: ['bogus-nothing'] });

    for (const type of PerformanceObserver.supportedEntryTypes) {
        out['buffer ' + type] = performance.getEntriesByType(type).length;
    }
    return out;
})()
