// Bisect Cloudflare's verdict with a knob, on the arm that passes.
//
//   node tools/fingerprint/cf-knob.mjs <lightpanda|chrome> --knob <name> [--runs N] [--port P]
//   node tools/fingerprint/cf-knob.mjs chrome --list
//
// cf-verdict.mjs answers "does this engine get a ticket". This answers "does
// THIS ONE CHANGE cost a ticket", by injecting a script into the challenge
// before the guard runs and reading the same `cf-chl-out` off the second `fo/`
// POST's response.
//
// The carrier is Chrome, not this engine: Chrome holds a ticket on
// cf-scrapingcourse, so every knob starts from a pass and a lost ticket is a
// signal rather than noise. Breaking one family at a time in a browser that
// otherwise passes is the only way to learn which family the station WEIGHS --
// which is a different question from where the two engines differ, and the
// x-hyatt work is what taught that: Chrome sent a fake timezone, an empty codec
// list, zeroed geometry and an empty voice list all at once and kept its ticket.
//
// Two things this has to get right that the Kasada version did not:
//
//   * **the widget is a separate target.** Chrome isolates
//     challenges.cloudflare.com, so `Page.addScriptToEvaluateOnNewDocument` on
//     the page's session never reaches the frame that builds the ~90KB payload.
//     The knob is installed on every auto-attached target, and the `alive`
//     control exists to prove it arrived in both.
//   * `Network.enable` takes `maxPostDataSize`, without which the round that
//     matters reports no body at all.
//
// `Page.enable` must precede `addScriptToEvaluateOnNewDocument` or Chrome
// accepts the call and silently never runs the script -- which reads exactly
// like a knob that changed nothing.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, sleep } from './cdp.mjs';
import { CF_KNOBS } from './cf-knobs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };

if (process.argv.includes('--list')) {
    console.log(Object.keys(CF_KNOBS).join('\n'));
    process.exit(0);
}
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: cf-knob.mjs <lightpanda|chrome> --knob <name> [--runs N] [--port P] [--url U] [--settle MS] [--headless] [--out PATH]');
    process.exit(2);
}
const knobName = arg('--knob', 'none');
if (!(knobName in CF_KNOBS)) {
    console.error(`unknown knob '${knobName}'. --list to see them.`);
    process.exit(2);
}
const knobSrc = CF_KNOBS[knobName];
const runs = Number(arg('--runs', 2));
const basePort = Number(arg('--port', 9470));
const target = arg('--url', 'https://www.scrapingcourse.com/antibot-challenge');
const settle = Number(arg('--settle', 22000));
const outPath = arg('--out', null);
const headless = process.argv.includes('--headless');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36';

const isChallenge = (url) =>
    url.includes('/cdn-cgi/challenge-platform/') || url.includes('challenges.cloudflare.com');

async function once(port) {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'cf-knob-'));
    const proc = engine === 'chrome'
        ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
            '--no-first-run', '--no-default-browser-check', `--user-agent=${UA}`,
            ...(headless ? ['--headless=new'] : [])],
        { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port)],
            { stdio: ['ignore', 'pipe', 'pipe'] });
    proc.stdout.resume();
    proc.stderr.resume();
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    const out = { documents: [], challenge: [], beacons: [], targets: 0 };
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        const posted = new Map();

        // Everything the knob reports comes back as a URL, because a knob that
        // reports over the console would need Runtime.enable and a knob that
        // reports nothing cannot be told apart from a knob that never ran.
        const beaconPrefix = '/__cfknob?';
        const install = async (sid) => {
            out.targets += 1;
            try { await cdp.send('Page.enable', {}, sid); } catch { /* not a page */ }
            try { await cdp.send('Network.enable', { maxPostDataSize: 1 << 21 }, sid); } catch { /* gone */ }
            if (knobSrc) {
                try {
                    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: knobSrc }, sid);
                } catch { /* cannot script this target */ }
            }
            try {
                await cdp.send('Target.setAutoAttach',
                    { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sid);
            } catch { /* does not nest */ }
        };

        cdp.on((m) => {
            if (m.method === 'Target.attachedToTarget') { install(m.params.sessionId); return; }
            if (m.method === 'Network.requestWillBeSent') {
                const url = String(m.params.request?.url || '');
                if (url.includes(beaconPrefix)) {
                    out.beacons.push(decodeURIComponent(url.split(beaconPrefix)[1] || ''));
                    return;
                }
                if (!isChallenge(url)) return;
                posted.set(m.params.requestId, {
                    method: m.params.request.method,
                    postLen: (m.params.request.postData || '').length,
                    postUnknown: !m.params.request.postData && !!m.params.request.hasPostData,
                });
                return;
            }
            if (m.method !== 'Network.responseReceived') return;
            const r = m.params.response;
            const url = String(r.url);
            if (m.params.type === 'Document') out.documents.push(r.status);
            if (!isChallenge(url)) return;
            const h = r.headers || {};
            const sent = posted.get(m.params.requestId) || {};
            out.challenge.push({
                path: url.replace(/^https?:\/\/[^/]+/, '').split('?')[0],
                method: sent.method || 'GET',
                postLen: sent.postLen || 0,
                postUnknown: !!sent.postUnknown,
                status: r.status,
                chlGen: h['cf-chl-gen'] ?? null,
                chlOut: h['cf-chl-out'] ?? null,
            });
        });

        await install(sessionId);
        await cdp.send('Page.navigate', { url: target }, sessionId);
        await sleep(settle);
    } finally {
        cdp.close();
        proc.kill('SIGKILL');
        await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
    }
    return out;
}

const all = [];
for (let i = 0; i < runs; i++) {
    const out = await once(basePort + i);
    all.push(out);
    const fo = out.challenge.filter((c) => c.path.includes('/fo/'));
    const ticket = fo.find((c) => c.chlOut);
    const rounds = fo.map((c, n) => `r${n + 1}:${c.postUnknown ? '?' : c.postLen}B` +
        (c.chlOut ? '=TICKET' : c.chlGen ? '=gen' : '')).join(' ');
    console.log(`${engine}${headless ? ' (headless)' : ''} knob=${knobName} run ${i + 1}: ` +
        `doc=${out.documents.join('->') || '(none)'} ` +
        `ticket=${ticket ? String(ticket.chlOut).slice(0, 10) : '(absent)'} ` +
        `targets=${out.targets} beacons=${out.beacons.length} rounds=[${rounds}]`);
    if (out.beacons.length) {
        const shown = [...new Set(out.beacons)].slice(0, 6);
        console.log(`      beacons: ${shown.join(' | ')}${out.beacons.length > shown.length ? ' …' : ''}`);
    }
}

if (outPath) {
    await fs.writeFile(outPath, JSON.stringify({ engine, knob: knobName, headless, target, runs: all }, null, 2));
    console.log(`wrote ${outPath}`);
}
