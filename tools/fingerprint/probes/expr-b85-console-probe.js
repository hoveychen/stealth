// What a page can observe about how `console` treats its arguments.
//
// Found in Cloudflare's own debug output on cf-scrapingcourse: the challenge
// sweeps every console method twice, and the arms part in five places. Chrome
// emits `startGroupCollapsed` / `endGroup` / `count` / `table` events this engine
// emits none of, one probe reads `a` on Chrome and `object` here, and the whole
// `%c%d` sweep reads `NaN` on Chrome and `Error` here.
//
// The last one is the interesting one, because it is the only one a PAGE can
// see. `console.log('%c%d', style, obj)` prints somewhere the page cannot read
// -- but `%d` has to coerce its argument to a number, and coercion calls
// `valueOf`. So an object with a recording `valueOf`/`toString` learns whether
// the coercion happened at all, and that is a fingerprint the guard collects
// without needing devtools open.
//
// This probe asks that question directly rather than through CDP's report of
// what console received: every console method, each of the format specifiers,
// against an argument that records every coercion path taken. Nothing here
// depends on the console's output being visible.
(() => {
    const out = {};

    // An argument that records how it was coerced. `%d` should reach valueOf,
    // `%s` should reach toString, `%o`/`%O` should reach neither.
    const makeSpy = () => {
        const seen = [];
        const spy = {
            valueOf() { seen.push('valueOf'); return NaN; },
            toString() { seen.push('toString'); return 'a'; },
            get [Symbol.toPrimitive]() { seen.push('toPrimitive'); return undefined; },
        };
        return { spy, seen };
    };

    const METHODS = ['log', 'debug', 'info', 'warn', 'error', 'trace', 'dir', 'dirxml',
        'table', 'count', 'group', 'groupCollapsed', 'groupEnd', 'assert', 'time', 'timeEnd'];

    // 1. Which console methods exist at all, and what they report about
    //    themselves. A missing method is the crudest tell of the set.
    out['methods.present'] = METHODS.filter((m) => typeof console[m] === 'function').join(',');
    out['methods.missing'] = METHODS.filter((m) => typeof console[m] !== 'function').join(',');
    out['methods.count'] = String(Object.getOwnPropertyNames(console).length);

    // 2. The coercion footprint of each format specifier, per method. This is
    //    the part the page can actually observe.
    for (const method of ['log', 'debug', 'info', 'warn', 'error', 'trace']) {
        if (typeof console[method] !== 'function') { out['coerce.' + method] = '(absent)'; continue; }
        const per = [];
        for (const fmt of ['%d', '%i', '%f', '%s', '%o', '%O', '%c%d']) {
            const { spy, seen } = makeSpy();
            try {
                if (fmt === '%c%d') console[method](fmt, 'font-size:0;color:transparent', spy);
                else console[method](fmt, spy);
            } catch (e) { seen.push('threw:' + e.name); }
            per.push(fmt + '=[' + seen.join('|') + ']');
        }
        out['coerce.' + method] = per.join(' ');
    }

    // 3. `%d` of an Error, which is the exact shape the challenge uses. Chrome's
    //    console reports NaN for it; what a page sees is whether valueOf ran.
    {
        const err = new Error('x');
        let touched = 'none';
        Object.defineProperty(err, 'valueOf', {
            configurable: true,
            value: () => { touched = 'valueOf'; return NaN; },
        });
        try { console.log('%c%d', 'font-size:0', err); } catch (e) { touched = 'threw'; }
        out['error.percentD'] = touched;
    }

    // 4. The return values, which are all undefined in a browser -- a console
    //    that returns anything else is a tell of its own.
    {
        const returns = [];
        for (const m of METHODS) {
            if (typeof console[m] !== 'function') continue;
            let r;
            try { r = console[m](); } catch (e) { r = 'threw:' + e.name; }
            returns.push(m + '=' + (r === undefined ? 'undefined' : String(r)));
        }
        out['returns'] = returns.join(' ');
    }

    // 5. console.count's own counter, which the challenge reads twice: Chrome
    //    answers 1 then 2 for the same label. It is state, so it is a thing to
    //    get wrong quietly.
    if (typeof console.count === 'function') {
        try {
            console.count('b85');
            console.count('b85');
            out['count.ok'] = 'called twice';
        } catch (e) { out['count.ok'] = 'threw:' + e.name; }
    } else {
        out['count.ok'] = '(absent)';
    }

    // 6. Descriptor shape of the console object itself.
    out['console.type'] = typeof console;
    out['console.toString'] = String(console);
    out['console.proto'] = Object.getPrototypeOf(console) === Object.prototype ? 'Object.prototype'
        : (Object.getPrototypeOf(console) === null ? 'null' : 'other');
    const d = Object.getOwnPropertyDescriptor(console, 'log');
    out['console.log.descriptor'] = d
        ? `writable=${d.writable} enumerable=${d.enumerable} configurable=${d.configurable}`
        : '(none)';
    out['console.log.length'] = String(console.log.length);
    out['console.log.name'] = String(console.log.name);
    out['console.log.toString'] = String(console.log);

    return out;
})();
