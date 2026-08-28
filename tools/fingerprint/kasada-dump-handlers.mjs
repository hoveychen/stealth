// Dump Kasada's interpreter, one opcode handler at a time.
//
//   node kasada-dump-handlers.mjs <ips.js file> [--out DIR] [--limit N]
//
// The program is a bytecode VM, and its opcode table is not in the source: the
// second pool is a `"...".split("C")` array behind a Proxy whose `get` trap
// decrypts one entry, wraps it in `new Function`, and caches the result. So
// there is no dispatch switch to read -- there are 187 handlers, each a piece
// of JavaScript that only exists once the interpreter asks for its opcode.
//
// Asking for all 187 from here gets the whole interpreter in source form,
// without the guard running: the Proxy, its decryptor and the pool it reads are
// all pure, so the lifted region simply ends after the `new Proxy(...)`
// statement instead of after the string heap.
//
// Same five-hour CRC window as kasada-decode-pool.mjs -- the prelude that
// builds the integer pool is shared, so an expired ips.js yields nothing here
// either.
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
const file = process.argv[2];
const outDir = arg('--out', path.join(here, 'scratch', 'handlers'));
const limit = Number(arg('--limit', '200'));
const src = await fs.readFile(file, 'utf8');

const bodyStart = src.indexOf('(function(){');
const px = src.indexOf('=new Proxy(');
if (bodyStart === -1 || px === -1) { console.error('not a Kasada program'); process.exit(2); }
const proxyVar = /(\w+)=new Proxy\($/.exec(src.slice(0, px + 11))?.[1];

// Balance parentheses from `new Proxy(`, stepping over the two string literals
// so a `(` inside the base-61 pool does not throw the count off.
let depth = 0, end = -1;
for (let i = src.indexOf('(', px); i < src.length; i++) {
    const c = src[i];
    if (c === '"') { i++; while (src[i] !== '"') { if (src[i] === '\\') i++; i++; } continue; }
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) { end = i + 1; break; } }
}
if (end === -1 || !proxyVar) { console.error('could not delimit the Proxy statement'); process.exit(2); }

// eslint-disable-next-line no-new-func
const table = new Function('window', `${src.slice(bodyStart + '(function(){'.length, end)};\nreturn ${proxyVar};`)({ Promise });

await fs.mkdir(outDir, { recursive: true });
const base = path.basename(file).replace(/\.txt$/, '');
const dir = path.join(outDir, base);
await fs.mkdir(dir, { recursive: true });

// Two keys, not one. `var C = a ? E : 49` picks between a constant and `E`,
// and `E` is reset at runtime through the same trap (`if (Number.isNaN(C) &&
// a !== v) return function (V) { E = V }`). So the handlers whose entry carries
// the marker character stay encrypted until the program is running, and lifting
// the table statically decrypts only the other 77.
//
// The plaintext is JavaScript, though, so the runtime key is recoverable
// without the program: XOR is `ch = n ^ (key + i % 11)`, the body must be
// printable ASCII, and only one key in the range makes 110 separate bodies come
// out printable at once.
const alpha = /var \w+="([A-Za-z0-9]{50,80})";var \w+=\w+\[Math/.exec(src);
const radix = /\(\w+,\w+,(\d+)\)\.map\(/.exec(src);
const lit = /"([A-Za-z0-9]{4000,})"\.split\("(\w)"\)/.exec(src);
let brute = null;
if (alpha && radix && lit) {
    const T = alpha[1], a = Number(radix[1]);
    // `d(u,f,a)` from the prelude: variable-length base-`a` over alphabet `f`.
    const dec = (u) => {
        const h = T.length, r = h - a, n = [], map = new Map();
        for (let t = 0; t < h; t++) map.set(T[t], t);
        for (let w = 0; w < u.length;) {
            for (let l = 0, M = 1; ;) {
                const x = map.get(u[w++]) || 0;
                if (x < a) { l += M * x; n.push(l | 0); break; }
                l += M * (x % a + a); M *= r;
            }
        }
        return n;
    };
    const arr = lit[1].split(lit[2]);
    const marker = T[1];
    const enc = arr.map((w) => (w.slice(-1) === marker ? dec(w.slice(0, -1)) : null));
    const printable = (nums, key) => {
        for (let i = 0; i < nums.length; i++) {
            const c = nums[i] ^ (key + i % 11);
            if (c < 9 || c > 126) return false;
        }
        return true;
    };
    const bodies = enc.filter(Boolean);
    let best = null, bestHits = 0;
    for (let key = -70000; key < 70000 && bodies.length; key++) {
        let hits = 0;
        for (const b of bodies) if (printable(b, key)) hits++;
        if (hits > bestHits) { bestHits = hits; best = key; }
        if (bestHits === bodies.length) break;
    }
    if (best !== null && bestHits > bodies.length * 0.9) {
        brute = { key: best, hits: bestHits, of: bodies.length, enc };
        console.log(`runtime key recovered: E=${best} (${bestHits}/${bodies.length} bodies printable)`);
    } else {
        console.log(`runtime key not recovered (best ${bestHits}/${bodies.length})`);
    }
}

const rows = [];
for (let op = 0; op < limit; op++) {
    let text;
    try {
        const fn = table[op];
        if (typeof fn !== 'function') break;
        text = Function.prototype.toString.call(fn);
    } catch (e) {
        rows.push({ op, error: String(e && e.message).slice(0, 100) });
        continue;
    }
    // Non-ASCII means this handler used the runtime key; re-decrypt it with the
    // recovered one and keep the prefix the Proxy prepends.
    let source = 'static';
    if (brute && /[^\x00-\x7f]/.test(text) && brute.enc[op]) {
        const body = brute.enc[op].map((n, i) => String.fromCharCode(n ^ (brute.key + i % 11))).join('');
        const head = text.slice(0, text.indexOf('{') + 1);
        text = `${head}${body}}`;
        source = 'runtime-key';
    }
    await fs.writeFile(path.join(dir, `op${String(op).padStart(3, '0')}.js`), text);
    rows.push({ op, bytes: text.length, source, sha1: crypto.createHash('sha1').update(text).digest('hex').slice(0, 10) });
}
await fs.writeFile(path.join(dir, 'index.json'), JSON.stringify(rows, null, 1));
const ok = rows.filter((r) => r.bytes);
console.log(`${ok.length} handlers decrypted -> ${dir}`);
console.log(`  total ${ok.reduce((a, r) => a + r.bytes, 0)} bytes, ` +
    `smallest ${Math.min(...ok.map((r) => r.bytes))}, largest ${Math.max(...ok.map((r) => r.bytes))}`);
for (const r of rows.filter((x) => x.error).slice(0, 5)) console.log(`  op${r.op} ERR ${r.error}`);
