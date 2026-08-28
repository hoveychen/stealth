// Decode the Kasada program's constant pool without running the program.
//
//   node kasada-decode-pool.mjs <ips.js file> [--out DIR]
//
// ips.js is a bytecode VM. Its 543KB body is one string literal in a custom
// base-44 alphabet; a pure prelude function turns it into an integer array, and
// the interpreter reads operands out of that array by type tag. Nothing in the
// prelude touches the DOM, so it can be lifted out and run here -- which gets
// the guard's own constants without the guard ever running, and so without the
// station learning anything.
//
// The prelude self-checks: it seeds off `Math.round(+new Date/18000081)` and
// bails on a CRC mismatch, so a pool decodes only within roughly five hours of
// the fetch that produced it. An empty result on an old file is that window
// closing, not a decoder that broke.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
const file = process.argv[2];
const outDir = arg('--out', path.join(here, 'scratch', 'pool'));
const src = await fs.readFile(file, 'utf8');

// `var t=A(H,"<alphabet>",44);` -- every name is re-minified per fetch, so match
// the shape rather than the names. The alphabet never contains a double quote.
const m = /var (\w+)=(\w+)\((\w+),"([^"]*)",(\d+)\);/.exec(src);
if (!m) { console.error('no `var t=A(H,"...",N);` statement found'); process.exit(2); }
const [stmt, poolVar, , , alphabet, radix] = m;
const bodyStart = src.indexOf('(function(){');
if (bodyStart === -1) { console.error('no IIFE'); process.exit(2); }
const prelude = src.slice(bodyStart + '(function(){'.length, m.index + stmt.length);

// eslint-disable-next-line no-new-func
const pool = new Function(`${prelude}\nreturn ${poolVar};`)();
console.log(`alphabet=${alphabet.length} chars radix=${radix} pool=${Array.isArray(pool) ? pool.length : typeof pool} entries`);
if (!Array.isArray(pool) || pool.length === 0) {
    console.error('pool came back empty -- the five-hour CRC window on this file has closed; re-fetch ips.js');
    process.exit(3);
}

// Almost no string is stored inline. The operand decoder `g(u,f,a,h)` takes an
// accessor `h` whose `.x(len, off)` slices out of one packed heap, so a string
// operand is a pair of integers and the interpreter never holds a table of
// names. That heap is built once, a few statements further down:
//
//   P.x=function(e,n){return P.n.slice(n,n+e)};
//   var m=t[f+L.indexOf(".")]^p; var K=t.splice(m,t[m+I.u[0]]+2);
//   P.n=g(K,I.u[1].u,y)
//
// Nothing in there is DOM-dependent either -- `window` is read for `Promise`
// and for nothing else this far up -- so extending the lifted prelude through
// that block yields the heap itself: every string constant the guard can name.
const ty = /var (\w+)=\[(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\];/.exec(src);
if (!ty) { console.error('no six-entry type tag table found'); process.exit(2); }
console.log('type tags:', ty.slice(2).map(Number).join(','));

// Balance braces from the block that follows the tag table to find its end.
let bi = src.indexOf('{', ty.index + ty[0].length);
let depth = 0, bend = -1;
for (let i = bi; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) { bend = i + 1; break; } }
}
const block = src.slice(bi, bend);
const pm = /(\w+)\.x=function/.exec(block);
if (bend === -1 || !pm) { console.error('could not delimit the heap-building block'); process.exit(2); }

// `var O=window` is the only global the lifted region needs, and it only ever
// reaches `.Promise` before the heap is built.
// Building the heap splices its own bytes out of the pool, so take the pool
// back from the same call: the indices below have to match what the
// interpreter will actually walk.
const lifted = new Function('window',
    `${src.slice(bodyStart + '(function(){'.length, bend)}\nreturn [${pm[1]}.n, ${poolVar}];`)({ Promise });
const [heap, code] = lifted;
if (typeof heap !== 'string' || heap.length === 0) {
    console.error('heap came back empty:', typeof heap);
    process.exit(3);
}

// A string operand is the triple [tag, len, off] -- `h.x(e,n)` slices
// `heap.slice(n, n+e)`. Requiring the slice to land inside the heap and to be
// printable is what separates a real operand from a run of integers that
// happens to start with the tag.
const STR = Number(ty[7]);
const names = new Map();
for (let i = 0; i + 2 < code.length; i++) {
    if (code[i] !== STR) continue;
    const len = code[i + 1], off = code[i + 2];
    if (!Number.isInteger(len) || !Number.isInteger(off)) continue;
    if (len < 1 || off < 0 || off + len > heap.length) continue;
    const s = heap.slice(off, off + len);
    if (!/^[\x20-\x7e -￿]+$/.test(s)) continue;
    if (!names.has(s)) names.set(s, { off, len, hits: 0 });
    names.get(s).hits++;
}
const sorted = [...names.entries()].sort((a, b) => a[1].off - b[1].off);

await fs.mkdir(outDir, { recursive: true });
const base = path.basename(file).replace(/\.txt$/, '');
await fs.writeFile(path.join(outDir, `${base}.pool.json`), JSON.stringify(code));
await fs.writeFile(path.join(outDir, `${base}.heap.txt`), heap);
await fs.writeFile(path.join(outDir, `${base}.names.txt`), sorted.map(([s]) => s).join('\n'));
console.log(`string heap: ${heap.length} chars -> ${path.join(outDir, `${base}.heap.txt`)}`);
console.log(`${names.size} distinct string operands -> ${path.join(outDir, `${base}.names.txt`)}`);
