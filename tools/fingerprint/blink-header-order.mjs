// Predicts the order Chrome puts request header fields on the wire.
//
//   node tools/fingerprint/blink-header-order.mjs X-Zeta X-Alpha
//
// Chrome does not have a *slot* for an author header. The renderer keeps request
// headers in `HTTPHeaderMap`, which is
// `HashMap<AtomicString, AtomicString, DeprecatedCaseFoldingHashTraits<...>>`,
// and the order that reaches the network service -- and from there the wire, h1
// and h2 alike -- is that hash table's bucket order. So the position of every
// field, the engine's own included, is a function of the whole set of names
// present: adding one author header can move `user-agent`.
//
// Two ingredients, both fixed constants in Chromium rather than per-process
// randomised (which is why the order is stable across browser launches, and
// therefore reproducible at all):
//
//   * the hash -- rapidhash (third_party/rapidhash/rapidhash.h) with RAPID_SEED
//     and the default secret triplet, over the case-folded name expanded to
//     UTF-16, masked to the low 24 bits (StringHasher reserves the top 8 for
//     StringImpl flags);
//   * the table -- WTF::HashTable: power-of-two size from 8, max load 1/2,
//     doubling, `i = (i + ++probe) & mask` on collision, iteration from bucket
//     0 upward.
//
// Fitted against measured Chrome 151 orders (b59-*.json) and it reproduces
// every one of them under a single rule: author headers enter the map first in
// the order the page set them, then the engine's own fields in the fixed order
// in ENGINE_FIELDS.
const M64 = (1n << 64n) - 1n;
const M128 = (1n << 128n) - 1n;
const SECRET = [0x2d358dccaa6c78a5n, 0x8bb84b93962eacc9n, 0x4b33a62ed433d4a3n];
const SEED = 0xbdd89aa982704029n;

const mul128 = (a, b) => {
    const r = (a * b) & M128;
    return [r & M64, (r >> 64n) & M64];
};
const mix = (a, b) => {
    const [lo, hi] = mul128(a, b);
    return (lo ^ hi) & M64;
};
const readLE = (buf, off, n) => {
    let v = 0n;
    for (let i = n - 1; i >= 0; i--) v = (v << 8n) | BigInt(buf[off + i] ?? 0);
    return v;
};
const read64 = (b, o) => readLE(b, o, 8);
const read32 = (b, o) => readLE(b, o, 4);

// A transcription of third_party/rapidhash/rapidhash.h with the plain reader.
// The case folding and the Latin1-to-UTF-16 expansion that Chromium does inside
// its reader happen in nameHash() instead, on a materialised buffer: same bytes,
// same length, and far easier to read than the `* x / y` pointer arithmetic.
function rapidhash(buf) {
    const len = buf.length;
    let seed = (SEED ^ mix(SEED ^ SECRET[0], SECRET[1]) ^ BigInt(len)) & M64;
    let a, b, p = 0;
    if (len <= 16) {
        if (len >= 4) {
            const plast = len - 4;
            a = ((read32(buf, 0) << 32n) | read32(buf, plast)) & M64;
            const delta = (len & 24) >> (len >> 3);
            b = ((read32(buf, delta) << 32n) | read32(buf, plast - delta)) & M64;
        } else if (len > 0) {
            a = ((BigInt(buf[0]) << 56n) | (BigInt(buf[len >> 1]) << 32n) | BigInt(buf[len - 1])) & M64;
            b = 0n;
        } else {
            a = b = 0n;
        }
    } else {
        let i = len;
        if (i > 48) {
            let see1 = seed, see2 = seed;
            do {
                seed = mix(read64(buf, p) ^ SECRET[0], read64(buf, p + 8) ^ seed);
                see1 = mix(read64(buf, p + 16) ^ SECRET[1], read64(buf, p + 24) ^ see1);
                see2 = mix(read64(buf, p + 32) ^ SECRET[2], read64(buf, p + 40) ^ see2);
                p += 48;
                i -= 48;
            } while (i >= 48);
            seed = (seed ^ see1 ^ see2) & M64;
        }
        if (i > 16) {
            seed = mix(read64(buf, p) ^ SECRET[2], read64(buf, p + 8) ^ seed ^ SECRET[1]);
            if (i > 32) seed = mix(read64(buf, p + 16) ^ SECRET[2], read64(buf, p + 24) ^ seed);
        }
        a = read64(buf, p + i - 16);
        b = read64(buf, p + i - 8);
    }
    a = (a ^ SECRET[1]) & M64;
    b = (b ^ seed) & M64;
    [a, b] = mul128(a, b);
    return mix((a ^ SECRET[0] ^ BigInt(len)) & M64, (b ^ SECRET[1]) & M64);
}

// StringHasher::ComputeHashAndMaskTop8Bits through CaseFoldingHashReader.
export function nameHash(name) {
    const s = name.toLowerCase();
    const buf = new Uint8Array(s.length * 2);
    for (let i = 0; i < s.length; i++) buf[i * 2] = s.charCodeAt(i) & 0xff;
    const h = Number(rapidhash(buf) & 0xffffffn);
    return h || 0x00800000;
}

// The fields the engine puts in the same map as the author headers, in the order
// it inserts them. Everything else on the wire -- accept, origin, sec-fetch-*,
// referer, accept-encoding, accept-language, and h1's
// host/connection/content-length -- is added further down the stack to an
// ordered vector and always trails this block, in a fixed order, whatever the
// map does.
//
// The insertion order matters only where two names collide, so most measured
// cases cannot see it. Three can, and together they pin it: `hold-five` (x-ee
// against the hint block), and the two blocks in HttpClient.zig for an origin
// that asked for all nine hints, where sec-ch-ua collides with
// sec-ch-ua-bitness and user-agent with sec-ch-ua-full-version.
//
// What comes out is the hints in their declaration order -- the same sequence
// chrome_navigation_order has, which is the order the browser side writes them
// in too -- and User-Agent after them. Full nine below; a request carries the
// three baseline ones plus whatever its origin asked for via Accept-CH, and the
// absent names simply drop out of the sequence.
export const ENGINE_FIELDS = [
    'sec-ch-ua',
    'sec-ch-ua-mobile',
    'sec-ch-ua-full-version',
    'sec-ch-ua-arch',
    'sec-ch-ua-platform',
    'sec-ch-ua-platform-version',
    'sec-ch-ua-model',
    'sec-ch-ua-bitness',
    'sec-ch-ua-full-version-list',
    'user-agent',
];

// WTF::HashTable bucket order for a set of names inserted in the given order.
export function bucketOrder(names) {
    let size = 8;
    let table = new Array(size).fill(null);
    let count = 0;
    const place = (tbl, sz, name) => {
        const mask = sz - 1;
        let i = nameHash(name) & mask;
        let probe = 0;
        while (tbl[i] !== null) i = (i + ++probe) & mask;
        tbl[i] = name;
    };
    for (const name of names) {
        place(table, size, name);
        if (++count * 2 >= size) {
            const old = table;
            size *= 2;
            table = new Array(size).fill(null);
            for (const e of old) if (e !== null) place(table, size, e);
        }
    }
    return table.filter(Boolean);
}

// The three hints every request carries. The other six ride only on a request
// to an origin that asked for them via Accept-CH, which the local echo servers
// never do -- so this, not the whole list, is what a capture of them shows.
export const BASELINE_ENGINE_FIELDS =
    ENGINE_FIELDS.filter((n) => !n.startsWith('sec-ch-ua-') || n === 'sec-ch-ua-mobile' || n === 'sec-ch-ua-platform');

// The wire order of the scrambled block, for a page that set `authorNames` (in
// the order it set them). `engineFields` is the engine's own share of the map,
// in insertion order -- widen it for an origin that negotiated more hints.
export function order(authorNames, engineFields = BASELINE_ENGINE_FIELDS) {
    return bucketOrder([...authorNames, ...engineFields]);
}

// Fields the network stack appends to an ordered vector rather than the map, so
// they bracket the scrambled block instead of joining it. Stripped before a
// capture is scored.
const OUTSIDE_THE_MAP = new Set([
    'host', 'connection', 'content-length', 'accept', 'origin', 'sec-fetch-site',
    'sec-fetch-mode', 'sec-fetch-dest', 'sec-fetch-user', 'referer',
    'accept-encoding', 'accept-language', 'priority', 'cookie', 'cache-control',
    'pragma', 'upgrade-insecure-requests',
]);

// Scores a header-echo / h2-echo capture against the model. Exit 0 only if every
// case in AUTHOR_CASES was found and matched.
async function verify(file) {
    const fs = await import('node:fs/promises');
    const { AUTHOR_CASES } = await import('./header-echo.mjs');
    const capture = JSON.parse(await fs.readFile(file, 'utf8'));
    const first = new Map();
    for (const r of capture.requests ?? []) if (!first.has(r.path)) first.set(r.path, r);
    let ok = 0, missing = 0;
    for (const c of AUTHOR_CASES) {
        const rec = first.get(c.path);
        if (!rec) {
            console.log(`gone ${c.path}`);
            missing++;
            continue;
        }
        const got = rec.headers
            .map(([n]) => n.toLowerCase())
            .filter((n) => !n.startsWith(':') && !OUTSIDE_THE_MAP.has(n))
            .join(' | ');
        const want = order(c.headers.map(([n]) => n.toLowerCase())).join(' | ');
        if (got === want) {
            ok++;
        } else {
            console.log(`MISS ${c.path}\n     model ${want}\n     wire  ${got}`);
        }
    }
    console.log(`${ok}/${AUTHOR_CASES.length} cases match the model${missing ? `, ${missing} absent from the capture` : ''}`);
    process.exit(ok === AUTHOR_CASES.length ? 0 : 1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
    if (process.argv[2] === '--verify') {
        await verify(process.argv[3]);
    }
    const names = process.argv.slice(2);
    if (!names.length) {
        console.error('usage: blink-header-order.mjs <author-header-name>...');
        console.error('       blink-header-order.mjs --verify <capture.json>');
        process.exit(2);
    }
    for (const n of [...names, ...BASELINE_ENGINE_FIELDS]) {
        const h = nameHash(n);
        console.log(`  ${n.padEnd(24)} ${h.toString(16).padStart(6, '0')}  &7=${h & 7} &15=${h & 15} &31=${h & 31}`);
    }
    console.log(`\n${order(names).join(' | ')}`);
}
