// Give a Chrome profile a past, so the reference arm is not a first-ever visit.
//
//   node tools/fingerprint/warm-profile.mjs <profile-dir> [--rounds 2] [--headed]
//
// The door map's Chrome column is measured on a scratch profile, and on
// DataDome that column refuses every station -- including two this engine walks
// into (README, B89). A profile with no cookie, no history and no visit count
// is itself a signal, so before asking "is this engine detected" the reference
// has to stop being detectable for being brand new.
//
// Ordinary sites only, no guarded ones: the point is history and cookies, and
// hammering a challenge page is how a profile's reputation gets worse rather
// than better. Chrome is closed with SIGTERM because the cookie store is
// written on graceful shutdown -- a killed browser leaves an empty sqlite file.
//
// Measured on dd-leboncoin and dd-hermes, the two DataDome stations this engine
// walks into. Warmth alone does not do it and a head alone does not either:
//
//        | headless  | headed
//   fresh| challenge | challenge
//   warm | challenge | pass
//
// So the reference arm for a door map is `--profile-dir <warmed> --headed`.
// Anything else refuses stations this engine passes, and a column that refuses
// those cannot say which refusals are about the engine.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };
const profileDir = path.resolve(process.argv[2] || '');
if (!process.argv[2]) { console.error('usage: warm-profile.mjs <profile-dir> [--rounds N] [--headed]'); process.exit(2); }
const rounds = Number(arg('--rounds', 2));
const headed = process.argv.includes('--headed');
const port = Number(arg('--port', 9950));
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const SITES = [
    'https://en.wikipedia.org/wiki/Web_browser',
    'https://www.bbc.com/news',
    'https://news.ycombinator.com/',
    'https://www.gov.uk/',
    'https://developer.mozilla.org/en-US/docs/Web/HTTP',
    'https://www.nytimes.com/',
    'https://stackoverflow.com/questions',
    'https://www.imdb.com/',
];

await fs.mkdir(profileDir, { recursive: true });
const proc = spawn(CHROME, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check', ...personaScaleFlags(),
    '--window-size=1920,1080',
    ...(headed ? [] : ['--headless=new']),
], { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.resume();
proc.stderr.resume();
for (let i = 0; i < 200; i++) {
    try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
}

const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
let visited = 0;
try {
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Page.enable', {}, sessionId);
    for (let r = 0; r < rounds; r++) {
        for (const url of SITES) {
            try {
                await cdp.send('Page.navigate', { url }, sessionId);
                // Long enough for the page's own scripts to set their cookies;
                // a navigate that returns is not a page that has run.
                await sleep(4000);
                visited++;
                console.log(`  round ${r + 1}: ${url}`);
            } catch (e) {
                console.log(`  round ${r + 1}: ${url} -- ${e.message}`);
            }
        }
    }
} finally {
    cdp.close();
    const dead = new Promise((resolve) => proc.once('exit', resolve));
    proc.kill('SIGTERM');
    await Promise.race([dead, sleep(8000)]);
    proc.kill('SIGKILL');
}
console.log(`visited ${visited} pages into ${profileDir}`);
