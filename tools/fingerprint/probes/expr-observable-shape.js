// The shape and semantics of Chrome's Observable / Subscriber, and of
// EventTarget.when.
//
// The window realm is at 921 of 923 names and these two interfaces are the
// remainder. Today's guard-name census found both in the set Cloudflare's
// bytecode touches, so they are named as well as counted -- but the interesting
// half is the semantics, because a shell that answers the right names and the
// wrong behaviour is a worse tell than an absent one.
//
// Reports, for each interface: the prototype's own property names IN ORDER
// (Chrome's order is part of the fingerprint), each member's kind and arity,
// the constructor's own shape, and the descriptor flags. Then a behaviour trace
// of one subscription, because the call ORDER is what an implementation gets
// wrong.
(() => {
    const out = {};

    const describe = (name) => {
        const ctor = globalThis[name];
        if (typeof ctor !== 'function') return 'ABSENT';
        const proto = ctor.prototype;
        const own = Object.getOwnPropertyNames(proto);
        const members = own.map((k) => {
            const d = Object.getOwnPropertyDescriptor(proto, k);
            const flags = (d.enumerable ? 'e' : '-') + (d.configurable ? 'c' : '-') +
                (d.writable === undefined ? (d.get ? 'g' : '') + (d.set ? 's' : '') : (d.writable ? 'w' : '-'));
            const fn = d.value ?? d.get;
            const arity = typeof fn === 'function' ? fn.length : null;
            const kind = d.get ? 'accessor' : (typeof d.value);
            return `${k}:${kind}/${arity}/${flags}`;
        });
        return {
            ctorArity: ctor.length,
            ctorName: ctor.name,
            ctorOwn: Object.getOwnPropertyNames(ctor).join(','),
            protoOwnInOrder: own.join(','),
            members,
            toStringTag: proto[Symbol.toStringTag] ?? null,
            protoOf: Object.getPrototypeOf(proto) === Object.prototype ? 'Object.prototype' :
                (Object.getPrototypeOf(proto)?.constructor?.name ?? 'unknown'),
        };
    };

    out.Observable = describe('Observable');
    out.Subscriber = describe('Subscriber');
    out.eventTargetWhen = typeof EventTarget.prototype.when === 'function'
        ? `function/${EventTarget.prototype.when.length}`
        : String(typeof EventTarget.prototype.when);

    // One subscription, traced. The order of next/complete against teardown and
    // the value of `active` at each step is the part a shell cannot guess.
    out.trace = (() => {
        if (typeof Observable !== 'function') return 'ABSENT';
        const log = [];
        try {
            const o = new Observable((subscriber) => {
                log.push('init active=' + subscriber.active);
                log.push('signal=' + (subscriber.signal ? subscriber.signal.constructor.name : String(subscriber.signal)));
                subscriber.addTeardown(() => log.push('teardown active=' + subscriber.active));
                subscriber.next(1);
                subscriber.next(2);
                subscriber.complete();
                log.push('after complete active=' + subscriber.active);
                subscriber.next(3);
            });
            o.subscribe({
                next: (v) => log.push('next ' + v),
                error: (e) => log.push('error ' + e),
                complete: () => log.push('complete'),
            });
        } catch (e) {
            log.push('throw:' + e.message);
        }
        return log.join(' | ');
    })();

    // EventTarget.when, which is the reason the interfaces exist on window.
    out.whenTrace = (() => {
        if (typeof EventTarget.prototype.when !== 'function') return 'ABSENT';
        const log = [];
        try {
            const t = new EventTarget();
            const obs = t.when('x');
            log.push('when returns ' + (obs?.constructor?.name ?? typeof obs));
            const controller = new AbortController();
            obs.subscribe({ next: (e) => log.push('got ' + e.type) }, { signal: controller.signal });
            t.dispatchEvent(new Event('x'));
            controller.abort();
            t.dispatchEvent(new Event('x'));
            log.push('after abort, still ' + log.filter((l) => l.startsWith('got')).length);
        } catch (e) {
            log.push('throw:' + e.message);
        }
        return log.join(' | ');
    })();

    return out;
})()
