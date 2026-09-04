// What CreepJS renders for its speech row, and whether an earlier site changed it.
//
// The row is a race: CreepJS reads getVoices(), waits 50ms, and gives up 300ms
// later if no `localService` voice has arrived. So it reports hashes or
// `blocked` depending on whether anything asked for the voice list before it —
// in Chrome exactly as much as here, now that the wait is per browser rather
// than per document (webapi/speech/SpeechSynthesis.zig).
//
// `--warm <url>` visits another site first in the same browser, which is what a
// sweep does: `detector-sweep.mjs` puts sannysoft ahead of creepjs. Without it
// the browser reaches CreepJS cold.
//
// usage: node tools/fingerprint/creep-speech-row.mjs <chrome|lightpanda>
//            [--headed] [--warm <url>] [--settle MS] [--port P]
//
// Env: LP_BIN, CHROME
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags, PERSONA_DEVICE_SCALE_FACTOR } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, newPage, goto, evaluate, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2];
const arg = (name, dflt) => {
    const i = process.argv.indexOf(name);
    return i < 0 ? dflt : process.argv[i + 1];
};
const headed = process.argv.includes('--headed');
const warm = arg('--warm', null);
const settle = Number(arg('--settle', 24000));
const PORT = Number(arg('--port', 0)) || (engine === 'chrome' ? 17230 : 17231);
const CREEP = 'https://abrahamjuliot.github.io/creepjs/';
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LIGHTPANDA = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');

let proc, prof;
if (engine === 'chrome') {
    prof = await fs.mkdtemp(path.join(os.tmpdir(), 'creep-speech-'));
    const args = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(), '--window-size=1920,1080'];
    if (!headed) args.push('--headless=new');
    proc = spawn(CHROME, args, { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 300; i++) {
    try { await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(100); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
let sessionId;
if (engine === 'chrome') {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    ({ sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
} else {
    ({ sessionId } = await newPage(cdp));
    await cdp.send('Runtime.enable', {}, sessionId);
}
const [w, h] = [1920, 1080];
await cdp.send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: engine === 'chrome' ? PERSONA_DEVICE_SCALE_FACTOR : 1, mobile: false }, sessionId);

const out = { engine, headed, warm, settle };
if (warm) {
    await goto(cdp, sessionId, warm, { settleMs: 8000 });
    out.warmVoices = await evaluate(cdp, sessionId,
        'window.speechSynthesis ? speechSynthesis.getVoices().length : "absent"').catch((e) => String(e));
}
await goto(cdp, sessionId, CREEP, { settleMs: settle });

// The row is whatever CreepJS printed next to its speech heading. Take the text
// rather than a selector: the site's markup has changed under this harness
// before, and the words are what the earlier readings were quoted from.
const text = await evaluate(cdp, sessionId, '(document.body && document.body.innerText) || ""');
out.textLength = text.length;
const flat = text.replace(/\s+/g, ' ');
const i = flat.toLowerCase().indexOf('speech');
out.row = i < 0 ? null : flat.slice(i, i + 200);
out.hashes = (flat.match(/(local|remote|lang) \(\d+\)\s*:?\s*[0-9a-f]{8}/g) || []);
out.blocked = /speech/i.test(flat) && /local \(0\)|blocked/i.test(out.row || '');

console.log(JSON.stringify(out, null, 1));

cdp.close();
proc.kill('SIGKILL');
if (prof) await fs.rm(prof, { recursive: true, force: true });
process.exit(0);
