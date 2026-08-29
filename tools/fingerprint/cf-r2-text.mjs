// Reassemble the strings `report-r2-text` chunked out, and diff two arms.
//
//   node tools/fingerprint/cf-r2-text.mjs <run.json> [more.json ...] --dir OUT
//   node tools/fingerprint/cf-r2-text.mjs --diff A.json B.json
//
// `report-r2-text` sends a header line per string and then the content in
// 300-character hex chunks. This puts them back together, checks the hash the
// knob computed in the page against one computed here -- a chunk lost on the
// wire is otherwise invisible -- and writes each string to a file.
//
// `--diff` lines the two arms up by string and, for the pair that is the r2
// body, reports the first offset at which they part company. That is the whole
// point: 180 bytes cannot be seen in a length.
import fs from 'node:fs/promises';
import path from 'node:path';

const args = process.argv.slice(2);
const arg = (n, d) => { const i = args.indexOf(n); return i !== -1 ? args[i + 1] : d; };
const files = args.filter((a, i) => !a.startsWith('--') && args[i - 1] !== '--dir');
if (!files.length) {
    console.error('usage: cf-r2-text.mjs <run.json ...> [--dir OUT] | --diff A.json B.json');
    process.exit(2);
}

const hash = (s) => {
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return h.toString(36);
};

const unhex = (d) => {
    let o = '';
    for (let i = 0; i + 4 <= d.length; i += 4) o += String.fromCharCode(parseInt(d.slice(i, i + 4), 16));
    return o;
};

// One file can hold several runs, and a string caught in run 2 is not the same
// sighting as the identically named one in run 1. Keyed by run index so a
// partial capture in one run cannot be silently completed by another.
async function readRuns(file) {
    const j = JSON.parse(await fs.readFile(file, 'utf8'));
    const out = [];
    for (const [ri, run] of (j.runs || []).entries()) {
        const heads = new Map();
        const chunks = new Map();
        for (const raw of new Set(run.beacons || [])) {
            const kv = Object.create(null);
            for (const pair of String(raw).split('&')) {
                const eq = pair.indexOf('=');
                if (eq === -1) continue;
                kv[pair.slice(0, eq)] = pair.slice(eq + 1);
            }
            if (kv.txt !== undefined && kv.parts !== undefined) {
                heads.set(kv.txt, { len: +kv.len, h: kv.h, parts: +kv.parts, at: decodeURIComponent(kv.at || '') });
            } else if (kv.chunk !== undefined && kv.i !== undefined) {
                if (!chunks.has(kv.chunk)) chunks.set(kv.chunk, new Map());
                chunks.get(kv.chunk).set(+kv.i, kv.d || '');
            }
        }
        const strings = [];
        for (const [id, head] of heads) {
            const got = chunks.get(id) || new Map();
            const missing = [];
            let text = '';
            for (let i = 0; i < head.parts; i++) {
                if (!got.has(i)) { missing.push(i); continue; }
                text += unhex(got.get(i));
            }
            strings.push({
                id, at: head.at, declaredLen: head.len, declaredHash: head.h,
                gotLen: text.length, gotHash: hash(text),
                complete: missing.length === 0 && text.length === head.len && hash(text) === head.h,
                missing, text,
            });
        }
        strings.sort((a, b) => b.declaredLen - a.declaredLen);
        out.push({ file, run: ri + 1, engine: j.engine, knob: j.knob, strings });
    }
    return out;
}

const firstDiff = (a, b) => {
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
    return a.length === b.length ? -1 : n;
};

if (args.includes('--diff')) {
    const [A, B] = files;
    const [ra, rb] = [await readRuns(A), await readRuns(B)];
    const pick = (runs) => runs.flatMap((r) => r.strings).filter((s) => s.complete);
    const sa = pick(ra), sb = pick(rb);
    console.log(`A ${A}: ${sa.length} complete strings`);
    for (const s of sa) console.log(`   ${String(s.declaredLen).padStart(7)}  ${s.declaredHash}  ${s.id}  @${s.at}`);
    console.log(`B ${B}: ${sb.length} complete strings`);
    for (const s of sb) console.log(`   ${String(s.declaredLen).padStart(7)}  ${s.declaredHash}  ${s.id}  @${s.at}`);
    // Same hash on both arms is the uninteresting case and it is the majority;
    // report only what is on one side alone or shared by prefix.
    const byHash = new Set(sb.map((s) => s.declaredHash));
    console.log('\nA-only (by hash):');
    for (const s of sa) if (!byHash.has(s.declaredHash)) {
        let best = null;
        for (const t of sb) {
            const d = firstDiff(s.text, t.text);
            if (d === -1) continue;
            if (!best || d > best.d) best = { d, t };
        }
        console.log(`   ${s.id} len=${s.declaredLen}` +
            (best ? ` | closest ${best.t.id} len=${best.t.declaredLen} shares ${best.d} chars` : ''));
        if (best) {
            const d = best.d;
            console.log(`     A[${d}..] ${JSON.stringify(s.text.slice(Math.max(0, d - 40), d + 80))}`);
            console.log(`     B[${d}..] ${JSON.stringify(best.t.text.slice(Math.max(0, d - 40), d + 80))}`);
        }
    }
    process.exit(0);
}

const dir = arg('--dir', null);
for (const f of files) {
    for (const r of await readRuns(f)) {
        console.log(`${r.file} run ${r.run} (${r.engine}, knob=${r.knob}): ${r.strings.length} strings`);
        for (const s of r.strings) {
            console.log(`   ${s.complete ? 'ok  ' : 'PART'} ${String(s.declaredLen).padStart(7)}` +
                ` h=${s.declaredHash}${s.complete ? '' : `/${s.gotHash} got=${s.gotLen} missing=${s.missing.length}`}` +
                `  ${s.id}  @${s.at}`);
            if (!dir) continue;
            await fs.mkdir(dir, { recursive: true });
            const name = `${r.engine}-run${r.run}-${s.id}${s.complete ? '' : '.PARTIAL'}.txt`;
            await fs.writeFile(path.join(dir, name), s.text);
        }
    }
}
if (dir) console.log(`wrote ${dir}`);
