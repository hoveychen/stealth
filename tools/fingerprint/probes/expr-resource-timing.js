// Does a subresource leave a `resource` PerformanceEntry behind?
//
// Cloudflare's own api.js reads the resource timing of itself and the page
// posts it to the widget as `apiJsResourceTiming` (README, "The widget realm
// assembles the same way"). On the station that field arrives as a 1 035-byte
// entry in Chrome and `undefined` here, which says the buffer is empty rather
// than that one entry is missing. This asks the question directly, off the
// station: fetch something, then look.
(async () => {
    const seen = () => performance.getEntriesByType('resource');
    const before = seen().length;
    try { await fetch(location.href + '?probe=1'); } catch (e) { /* offline is still an entry */ }
    // The entry is queued when the response completes, not when fetch resolves.
    await new Promise((r) => setTimeout(r, 300));
    const after = seen();
    return {
        classExists: typeof PerformanceResourceTiming,
        supportedEntryTypes: (PerformanceObserver.supportedEntryTypes || []).slice(),
        before,
        after: after.length,
        names: after.map((e) => String(e.name).slice(-40)),
        initiatorTypes: after.map((e) => e.initiatorType),
        allEntryTypes: performance.getEntries().map((e) => e.entryType),
    };
})()
