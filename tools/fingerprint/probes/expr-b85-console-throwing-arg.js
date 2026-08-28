// Does console swallow an exception from converting its argument?
//
// The formatter has to convert the argument for `%d`, and a `toString` that
// throws is the one case the earlier probes did not cover. Guessing it is not
// safe in either direction: swallowing where Chrome propagates hides an error a
// page expects to catch, and propagating where Chrome swallows makes console
// throw, which is a tell of its own.
(() => {
    const out = {};
    const boom = { toString() { throw new Error('boom'); } };
    for (const [name, run] of Object.entries({
        'log %d': () => console.log('%d', boom),
        'log %s': () => console.log('%s', boom),
        'log %o': () => console.log('%o', boom),
        'log plain': () => console.log(boom),
        'error %d': () => console.error('%d', boom),
        'group %d': () => console.group('%d', boom),
    })) {
        try { run(); out[name] = 'returned'; } catch (e) { out[name] = 'threw:' + e.message; }
    }
    // And a valueOf that throws, for the same question on the other path.
    const boomValue = { valueOf() { throw new Error('vboom'); }, toString() { return 'ok'; } };
    try { console.log('%d', boomValue); out['valueOf throws'] = 'returned'; }
    catch (e) { out['valueOf throws'] = 'threw:' + e.message; }
    return out;
})();
