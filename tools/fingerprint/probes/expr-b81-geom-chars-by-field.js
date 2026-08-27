// The /tl geometry character count, split by which reading the characters are
// in.
//
// scratch/expr-geom-chars.js answers one total, which is the number the payload
// attribution used (985 in Chrome against 816 here, ~169 characters). A total
// says how far apart the arms are and nothing about who is responsible, so this
// reports the same seven readings per field: same page, same order, same
// arithmetic, one line per field.
//
// Run against scratch/named-probe/geom-chars.html -- 40 rows of fractional
// percentage width and padding, each holding text -- with Chrome at
// `--force-device-scale-factor=2`, the factor this engine claims.
(() => {
    const els = [...document.querySelectorAll('#root div')];
    const fields = {};
    const bump = (name, value) => {
        const s = String(value);
        if (!fields[name]) fields[name] = { chars: 0, reads: 0, first: s };
        fields[name].chars += s.length;
        fields[name].reads += 1;
    };
    for (const el of els) {
        const cs = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        bump('computed width', cs.width);
        bump('computed height', cs.height);
        bump('computed padding-left', cs.paddingLeft);
        bump('rect width', r.width);
        bump('rect height', r.height);
        bump('offsetWidth', el.offsetWidth);
        bump('clientWidth', el.clientWidth);
    }
    const out = { elements: String(els.length) };
    let total = 0;
    for (const [name, f] of Object.entries(fields)) {
        out['field.' + name] = f.chars + ' chars / ' + f.reads + ' reads / first=' + f.first;
        total += f.chars;
    }
    out.total = String(total);
    return out;
})();
