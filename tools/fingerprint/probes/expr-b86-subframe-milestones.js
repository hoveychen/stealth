// Which resource entries carry their connection milestones, and does being in
// a cross-origin subframe change the answer?
//
// Run against probes/b86-subframe-fixture.mjs, which puts the parent on
// 127.0.0.1 and the child on localhost — same machine, two origins — and has
// EACH FRAME FETCH ITS OWN ORIGIN. Fetching across would measure the
// Timing-Allow-Origin rule, which zeroes these fields by spec, instead of the
// question being asked.
//
// Four initiator types per frame, because they do not share a code path here:
// `Frame.recordResourceTiming` says in its own comment that script/link/img go
// through it while "XHR and fetch call Performance directly", and only the
// first of those calls `setConnectionMilestones`. A probe that fired one
// initiator would report that split as a property of the frame.
//
//   node probes/b86-subframe-fixture.mjs 8710 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b86-subframe-milestones.js \
//        --url http://127.0.0.1:8710/parent.html
//   LP_BIN=... node tools/fingerprint/run-expr.mjs lightpanda <same probe> --url <same url>
//
// `zeros` is the verdict field: which of the nine connection milestones sit at
// exactly 0. Neither "is it zero" nor "is it non-zero" is the test on its own —
// `secureConnectionStart` is legitimately 0 over http, and a reused local
// connection legitimately reports connectStart == connectEnd == fetchStart —
// so what separates the arms is a field at 0 while its neighbours carry a
// timestamp.
(() => {
    const c = window.__collect;
    if (!c) return Promise.resolve({ error: 'fixture not loaded; serve.mjs must be the page' });

    const waitForChild = () => new Promise((resolve) => {
        const started = Date.now();
        const tick = () => {
            if (window.__child) return resolve(window.__child);
            if (Date.now() - started > 12000) return resolve(null);
            setTimeout(tick, 100);
        };
        tick();
    });

    return c.loadFour('http://127.0.0.1:' + location.port, 'top')
        .then(() => new Promise((r) => setTimeout(r, 400)))
        .then(waitForChild)
        .then((child) => {
            const out = {};
            const put = (where, list) => {
                out[where + '.count'] = String(list.length);
                for (const e of list) {
                    const k = where + '.' + e.initiatorType;
                    out[k + '.zeros'] = e.zeros;
                    out[k + '.fields'] = ['fetchStart', 'domainLookupStart', 'domainLookupEnd',
                        'connectStart', 'connectEnd', 'secureConnectionStart', 'requestStart',
                        'responseStart', 'responseEnd'].map((f) => f + '=' + e[f]).join(' ');
                }
            };
            put('top', c.readAll('top'));
            out['child.reported'] = String(!!child);
            put('child', (child && child.entries) || []);
            return out;
        });
})()
