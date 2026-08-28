// The edges of console's formatter, before implementing it.
//
// expr-b85-console-probe.js established the main fact: Chrome coerces the
// argument for `%d`/`%i`/`%f`/`%s` and not for `%o`/`%O`, and the coercion is
// page-observable because it calls `toString`. What it did not ask is what
// happens at the edges, and an implementation that guesses those will be wrong
// in a way the guard can also see.
//
// Each case records the coercion footprint of a spy argument, so "was it
// touched, and by which path" is the answer rather than what got printed.
(() => {
    const out = {};
    const makeSpy = (label) => {
        const seen = [];
        return {
            seen,
            spy: {
                valueOf() { seen.push('valueOf'); return 41; },
                toString() { seen.push('toString'); return label; },
                get [Symbol.toPrimitive]() { seen.push('toPrimitive'); return undefined; },
            },
        };
    };
    const probe = (name, run) => {
        const a = makeSpy('A');
        const b = makeSpy('B');
        try { run(a.spy, b.spy); } catch (e) { a.seen.push('threw:' + e.name); }
        out[name] = `first=[${a.seen.join('|')}] second=[${b.seen.join('|')}]`;
    };

    // Does `%c` coerce its style argument?
    probe('percentC style', (a) => console.log('%c', a));
    probe('percentC then d', (a, b) => console.log('%c%d', a, b));
    // `%%` is a literal percent and consumes nothing.
    probe('double percent', (a) => console.log('100%% %d', a));
    // An argument with no specifier to consume it.
    probe('excess arg', (a) => console.log('no specifiers', a));
    probe('excess after one', (a, b) => console.log('%d', a, b));
    // A specifier with no argument left.
    probe('missing arg', () => console.log('%d %d', 1));
    // An unknown specifier.
    probe('unknown specifier', (a) => console.log('%q', a));
    // A specifier that is not first in the string.
    probe('mid-string', (a) => console.log('x %s y', a));
    // The format string not being a string at all -- then there is no
    // formatting and nothing should be coerced.
    probe('non-string first', (a, b) => console.log(a, b));
    // `%j` is node's, not the web's.
    probe('percent j', (a) => console.log('%j', a));
    // Case: is it `%O` and `%o` both untouched, and `%S` unknown?
    probe('capital S', (a) => console.log('%S', a));
    // And the same question for the methods that are not `log`.
    probe('dir', (a) => console.dir('%d', a));
    probe('table', (a) => console.table('%d', a));
    probe('group', (a) => console.group('%d', a));
    probe('assert', (a) => console.assert(false, '%d', a));
    probe('count label', (a) => console.count(a));
    probe('time label', (a) => console.time(a));

    return out;
})();
