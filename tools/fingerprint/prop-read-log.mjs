// The engine's `prop_read` log, turned back into a list.
//
// Two drivers make the engine speak it -- prop-reads.mjs, which navigates and
// nothing else, and cf-knob.mjs --prop-reads, which navigates with a knob
// installed -- and both want the same three things out of it: which member,
// in which realm, in what order. Parsing it twice would mean two answers to
// "what counts as a member", which is exactly the question a two-arm diff of
// the name list rides on.
//
// The log's own shape:
//
//   $scope=prop_read property=Navigator.userAgent occurrences=2 seq=7 context=0

// `Window.matchMedia("(min-width: 100px)")` -> ['Window.matchMedia', '(min-width: 100px)'].
//
// The trailing group is anchored to the two shapes the engine emits -- a quoted
// string or a number -- rather than to "the last parenthesis", which an
// interface with no Meta.name would trip over: its Zig type name carries
// parens of its own, and a media query carries parens inside the argument.
export function splitArgument(name) {
    const m = /^(.*)\(("[\s\S]*"|-?[\d.][\deE+.-]*)\)$/.exec(name);
    if (!m) return [name, null];
    const raw = m[2];
    return [m[1], raw.startsWith('"') ? raw.slice(1, -1) : raw];
}

// The quoted form has to tolerate escapes: an interface with no Meta.name
// falls back to its Zig type name, and a generic one of those carries commas
// and quotes of its own (`Entry(...DOMStringList.Iterator,\"...`).
export function parsePropReads(text) {
    const reads = [];
    for (const line of String(text).split('\n')) {
        if (!line.includes('prop_read')) continue;
        const property = /property=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1];
        if (!property) continue;
        let name = property;
        if (name.startsWith('"')) {
            try { name = JSON.parse(name); } catch { name = name.slice(1, -1); }
        }
        // `scope=` is the log's own field (it says prop_read); the realm's url
        // is ours.
        const realm = /realm=("(?:[^"\\]|\\.)*"|\S+)/.exec(line)?.[1] ?? '';
        const [member, argument] = splitArgument(name);
        reads.push({
            context: Number(/context=(\d+)/.exec(line)?.[1] ?? -1),
            realm: realm.startsWith('"') ? realm.slice(1, -1) : realm,
            seq: Number(/seq=(\d+)/.exec(line)?.[1] ?? -1),
            property: name,
            member,
            ...(argument === null ? {} : { argument }),
            occurrences: Number(/occurrences=(\d+)/.exec(line)?.[1] ?? 0),
        });
    }
    // Grouped by context, then by the order within it. Every context counts
    // from zero, so a flat sort on `seq` would braid the page's walk together
    // with its iframes' into a sequence nothing performed.
    reads.sort((a, b) => (a.context - b.context) || (a.seq - b.seq));
    return reads;
}

// One row per realm: which document did the reading, and how much of the
// surface it reached. On this engine every frame is a context inside the one
// target, so this is where the widget's frame is told from the top document's.
export function contextsOf(reads) {
    return [...new Set(reads.map((r) => r.context))].map((id) => ({
        context: id,
        realm: reads.find((r) => r.context === id)?.realm,
        members: reads.filter((r) => r.context === id).length,
    }));
}
