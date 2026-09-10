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
import { Cdp, personaScaleFlags, sleep, assertPersonaParity, pinPersonaMedia } from './cdp.mjs';
import { headedUserAgent } from './fo-harness.mjs';
import { CF_KNOBS } from './cf-knobs.mjs';
import { parsePropReads, contextsOf } from './prop-read-log.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : d; };

// `--knob-file <path>` merges a scratch module's `KNOBS` export on top of the
// checked-in table, so a dose sweep that only exists for one session's question
// does not have to land in cf-knobs.mjs. Two sessions have already collided on
// that file -- one declaring a knob the other was deleting, leaving it
// unimportable, which reads exactly like a knob that changed nothing.
const knobFile = arg('--knob-file', null);
const EXTRA = knobFile ? (await import(path.resolve(process.cwd(), knobFile))).KNOBS : {};
const KNOBS = { ...CF_KNOBS, ...EXTRA };

if (process.argv.includes('--list')) {
    console.log(Object.keys(KNOBS).join('\n'));
    process.exit(0);
}
const engine = process.argv[2];
if (engine !== 'lightpanda' && engine !== 'chrome') {
    console.error('usage: cf-knob.mjs <lightpanda|chrome> --knob <name> [--knob-file MODULE] [--runs N] [--port P] [--url U] [--settle MS] [--headless] [--prop-reads [--prop-args]] [--out PATH]');
    process.exit(2);
}
const knobName = arg('--knob', 'none');
// `--knob a+b` runs both, each in its own function scope. Two knobs pasted
// together share a script scope and both start with the same `let` declarations,
// which is a syntax error and installs neither -- and a knob that never ran
// looks exactly like a knob that changed nothing. The main use is pairing a
// repair with a reporter, so that "the arm is still refused" can be told apart
// from "the repair never landed in the payload".
const parts = knobName.split('+');
for (const p of parts) {
    if (p in KNOBS) continue;
    console.error(`unknown knob '${p}'. --list to see them.`);
    process.exit(2);
}
// Report over the wire as well as into the stash. Costs the ticket on Chrome
// (one unexplained 404 inside the widget's frame stops the exchange at r1), so
// it is for the arm that has no ticket: this engine keeps every document in one
// target, and the per-session stash read cannot reach the widget's global there.
const wire = process.argv.includes('--beacon');
const body = parts.length === 1
    ? KNOBS[knobName]
    : parts.map((p) => (KNOBS[p] ? `(function () {\n${KNOBS[p]}\n})();` : '')).join('\n');
const knobSrc = body ? (wire ? 'globalThis.__CFK_WIRE = true;\n' : '') + body : body;
const runs = Number(arg('--runs', 2));
const basePort = Number(arg('--port', 9470));
const target = arg('--url', 'https://www.scrapingcourse.com/antibot-challenge');
// The station's own origin, so `served` is read off the page's documents and
// not off the widget's.
const origin = new URL(target).origin;
const settle = Number(arg('--settle', 22000));
const outPath = arg('--out', null);
const headless = process.argv.includes('--headless');
// Off by default, and the default is the finding: the challenge runs three blob
// workers on challenges.cloudflare.com, and evaluating into them is not free the
// way scripting a document is. Turn it on deliberately, and read the round count
// before reading anything else.
const intoWorkers = process.argv.includes('--workers');
// Chrome's --user-agent switch does not only replace the header: it empties the
// high-entropy client-hint metadata that goes with it, so
// getHighEntropyValues() answers "" for architecture, bitness, platformVersion
// and uaFullVersion and [] for fullVersionList and formFactors. The widget reads
// exactly those, which made the Chrome arm's first widget POST 179 bytes shorter
// than this engine's -- a gap that belonged to the harness. Pass --real-ua to
// leave the switch off and compare against a Chrome whose hints are populated.
const realUa = process.argv.includes('--real-ua');
// `--prop-reads` asks the engine which members the guard reached, in the same
// run the knob is installed in. prop-reads.mjs already answers that question,
// but it takes a URL and nothing else -- and a two-arm diff of the name list is
// only worth reading if both arms are the arms the ticket was measured on.
// Three things the engine needs, all of which the plain run gets wrong:
//
//   * a Debug binary. Outside Debug `bridge.logReads` hands the member back
//     unwrapped and no recorder exists, so the log is empty and looks exactly
//     like a guard that read nothing. `zig build install --prefix zig-out-dbg`,
//     then LP_BIN.
//   * the log has to be kept. `proc.stderr.resume()` throws it away.
//   * the targets have to be CLOSED. The dump happens when a context is torn
//     down; SIGKILL produces an empty log every time.
//
// Timing read off a Debug build is not comparable to anything
// ([[fingerprint-harness-runs-debug-build]]), so this is for the name list and
// the name list only -- and do not expect a ticket on this binary.
const propReads = process.argv.includes('--prop-reads');
const propArgs = process.argv.includes('--prop-args');

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LP = process.env.LP_BIN || path.join(repo, 'zig-out/bin/lightpanda');
// Ask the browser for its user agent instead of writing the version down.
//
// This was a hardcoded `Chrome/151.0.0.0`. Chrome moved to 152 and the guards
// began refusing the mismatch: on 2026-09-10 `cf-verdict.mjs` -- same constant,
// same use -- read `served=false` on BOTH arms including its control, on a
// station `antibot-sweep chrome --headed-ua` passed in the same minute. Nothing
// in the code had changed; the reference arm moved on its own. A criterion tool
// that silently reads false on a passing station invalidates every knob measured
// through it.
//
// Lazily, because only the Chrome arm sends it and probing costs a browser
// launch. The probe throws rather than falling back to a constant -- a silent
// fallback is how this failed in the first place.
let UA = null;
async function chromeUserAgent() {
    if (UA === null) UA = await headedUserAgent(basePort + 900);
    return UA;
}

const isChallenge = (url) =>
    url.includes('/cdn-cgi/challenge-platform/') || url.includes('challenges.cloudflare.com');

async function once(port) {
    const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'cf-knob-'));
    const proc = engine === 'chrome'
        ? spawn(CHROME, [`--remote-debugging-port=${port}`, `--user-data-dir=${tmp}`,
            '--no-first-run', '--no-default-browser-check',
            ...personaScaleFlags(),
            ...(realUa ? [] : [`--user-agent=${await chromeUserAgent()}`]),
            ...(headless ? ['--headless=new'] : [])],
        { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(port),
            ...(propReads ? ['--log-level', 'debug', '--log-format', 'logfmt',
                '--log-filter-scopes', '-all', '--log-filter-scopes', '+prop_read',
                ...(propArgs ? ['--log-filter-scopes', '+prop_arg'] : [])] : [])],
        { stdio: ['ignore', 'pipe', 'pipe'] });
    let engineLog = '';
    if (propReads) {
        const keep = (b) => { engineLog += b.toString(); };
        proc.stdout.on('data', keep);
        proc.stderr.on('data', keep);
    } else {
        proc.stdout.resume();
        proc.stderr.resume();
    }
    for (let i = 0; i < 200; i++) {
        try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await sleep(200); }
    }

    const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
    // `targets` used to be a bare count, and a count cannot tell a knob that
    // reached the widget from a knob that reached an empty about:blank iframe.
    // The widget is the document that builds the ~90KB payload the two arms
    // disagree on, so which targets were scripted is the difference between a
    // family that was tested and a family that only looks tested.
    const out = { documents: [], pageDocs: [], challenge: [], beacons: [], targets: 0, scripted: [] };
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        const posted = new Map();

        // Everything the knob reports comes back as a URL, because a knob that
        // reports over the console would need Runtime.enable and a knob that
        // reports nothing cannot be told apart from a knob that never ran.
        const beaconPrefix = '/__cfknob?';
        // Browser-level auto-attach also hands over the new-tab page, the
        // omnibox, and every installed extension's background worker. They are
        // not the challenge and scripting them only makes the log unreadable --
        // but they still have to be released, or a paused target hangs the run.
        const boring = (url) => /^(chrome|chrome-extension|chrome-untrusted|devtools):/.test(String(url));
        const seenTargets = new Set();
        const seenRequests = new Set();
        const installed = [];

        const install = async (sid, info) => {
            if (info && boring(info.url)) {
                try { await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid); } catch { /* gone */ }
                return;
            }
            // The same target is announced on more than one session now that
            // the root is attached too. Claim it by id before the first await,
            // so two announcements cannot both get past this.
            if (info) {
                if (seenTargets.has(info.targetId)) {
                    try { await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid); } catch { /* gone */ }
                    return;
                }
                seenTargets.add(info.targetId);
            }
            out.targets += 1;
            installed.push(sid);
            const tag = info ? `${info.type}:${String(info.url).slice(0, 60)}` : 'opener';
            try { await cdp.send('Page.enable', {}, sid); } catch { /* not a page */ }
            try { await cdp.send('Network.enable', { maxPostDataSize: 1 << 21 }, sid); } catch { /* gone */ }
            if (knobSrc) {
                // A worker has no Page domain, so the document hook does not
                // exist there; `waitForDebuggerOnStart` is what buys the chance
                // to evaluate before its own first line runs. The challenge
                // starts two blob workers on challenges.cloudflare.com, and
                // until this branch existed both were logged as FAILED and
                // nothing this session measured had ever been inside one.
                const worker = info && /worker/i.test(String(info.type));
                if (worker && !intoWorkers) {
                    out.scripted.push('skipped ' + tag);
                } else if (worker) {
                    // Deliberately not awaited. A worker paused on start does
                    // not answer Runtime.evaluate until it is released, so
                    // awaiting it here deadlocks: the release below is what the
                    // evaluate is waiting for. Awaiting it cost every round
                    // after the first -- the exchange stopped at r1 and the
                    // ticket vanished, which reads exactly like a knob the
                    // station judged.
                    cdp.send('Runtime.evaluate', { expression: knobSrc }, sid)
                        .catch(() => { out.scripted.push('worker-eval-failed ' + tag); });
                    out.scripted.push('worker-eval ' + tag);
                } else {
                    try {
                        await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: knobSrc }, sid);
                        out.scripted.push(tag);
                    } catch (e) { out.scripted.push('FAILED ' + tag + ' (' + (e && e.message || '') + ')'); }
                }
            } else {
                out.scripted.push(tag);
            }
            try {
                await cdp.send('Target.setAutoAttach',
                    { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid);
            } catch { /* does not nest */ }
            // Paired with waitForDebuggerOnStart above, and it has to be the
            // last thing: a target that is never released stays paused, and a
            // paused widget is a run that measures nothing.
            try { await cdp.send('Runtime.runIfWaitingForDebugger', {}, sid); } catch { /* not paused */ }
        };

        cdp.on((m) => {
            if (m.method === 'Target.attachedToTarget') {
                install(m.params.sessionId, m.params.targetInfo);
                return;
            }
            if (m.method === 'Network.requestWillBeSent') {
                if (seenRequests.has('s:' + m.params.requestId)) return;
                seenRequests.add('s:' + m.params.requestId);
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
                    reqHeaders: m.params.request.headers || {},
                    // Wall-clock, so the rounds can be placed on a timeline.
                    // The verdict rides on r3, and how long the widget took to
                    // get there is the one thing about it no knob has compared.
                    sentAt: Date.now(),
                });
                return;
            }
            // Chrome's requestWillBeSent carries only what the renderer knows;
            // the cookie, the Sec-Fetch-* set and the client hints are added
            // downstream and only appear here. Comparing the two arms on the
            // renderer's view alone has produced false differences before.
            if (m.method === 'Network.requestWillBeSentExtraInfo') {
                const p = posted.get(m.params.requestId);
                if (p) p.extraHeaders = m.params.headers || {};
                return;
            }
            if (m.method !== 'Network.responseReceived') return;
            // One response, two sessions, one row.
            if (seenRequests.has(m.params.requestId)) return;
            seenRequests.add(m.params.requestId);
            const r = m.params.response;
            const url = String(r.url);
            if (m.params.type === 'Document') {
                out.documents.push(r.status);
                // The same column cf-verdict grew, for the same reason: a
                // ticket is not a pass. `cf-mitigated: challenge` is what a
                // managed challenge carries and the served page does not, so a
                // knob that "works" has to be read here and not off the ticket.
                if (url.startsWith(origin)) {
                    out.pageDocs.push({ status: r.status, mitigated: (r.headers || {})['cf-mitigated'] || null });
                }
            }
            if (!isChallenge(url)) return;
            const h = r.headers || {};
            const sent = posted.get(m.params.requestId) || {};
            out.challenge.push({
                host: (url.match(/^https?:\/\/([^/]+)/) || [])[1] || '',
                path: url.replace(/^https?:\/\/[^/]+/, '').split('?')[0],
                method: sent.method || 'GET',
                postLen: sent.postLen || 0,
                postUnknown: !!sent.postUnknown,
                sentAt: sent.sentAt || 0,
                status: r.status,
                protocol: r.protocol ?? null,
                chlGen: h['cf-chl-gen'] ?? null,
                chlOut: h['cf-chl-out'] ?? null,
                // The whole header block and the body, because the refusal is
                // the server's own account of what it made of the payload and
                // reading two named headers off it throws the rest away.
                headers: h,
                reqHeaders: sent.reqHeaders || {},
                extraHeaders: sent.extraHeaders || {},
                requestId: m.params.requestId,
                sessionId: m.sessionId,
            });
        });
        // Bodies arrive later than the headers, so they are attached on the
        // finish event to the row the header event already made.
        cdp.on((m) => {
            if (m.method !== 'Network.loadingFinished') return;
            const row = out.challenge.find((c) => c.requestId === m.params.requestId);
            if (!row || row.body !== undefined) return;
            row.body = '(pending)';
            cdp.send('Network.getResponseBody', { requestId: m.params.requestId }, m.sessionId || row.sessionId)
                .then((b) => {
                    const s = String(b?.body ?? '');
                    // The flag is not decoration. One arm can hand back the
                    // same bytes base64-encoded and the other as text, and then
                    // the two lengths stand in a 4:3 ratio that reads exactly
                    // like the server having sent a bigger program.
                    row.base64 = !!b?.base64Encoded;
                    row.bodyLen = row.base64 ? Math.floor(s.replace(/=+$/, '').length * 3 / 4) : s.length;
                    row.rawLen = s.length;
                    row.body = s.slice(0, 4000);
                })
                .catch(() => { row.body = '(unavailable)'; });
        });

        // Browser-level auto-attach, on top of the per-session one.
        //
        // Attaching only through the page session was measured to miss the one
        // document that matters: `alive` reported from the top document and
        // from an empty about:blank iframe, never from
        // `challenges.cloudflare.com` -- while the same knob on this engine, a
        // single-target arm, reported from the widget's own frame. Every family
        // ruled out on the Chrome arm before this line was ruled out in the
        // wrong document. Chrome moves the widget into an out-of-process frame,
        // and the root session is where that arrival is announced.
        try {
            await cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
        } catch { /* older protocol */ }
        // Drain the knob's reports out of every session it was installed into,
        // repeatedly. Reading them here rather than beaconing them keeps the
        // knob's own traffic off the wire -- which is not a nicety: a single
        // beaconed 404 inside the widget's frame stops the exchange dead. And
        // it has to be repeated rather than done once at the end, because on a
        // passing run the challenge tears its own widget down the moment it
        // succeeds, taking the frame that holds the interesting report with it.
        const seenLines = new Set();
        const collect = async () => {
            for (const sid of [...installed]) {
                try {
                    const r = await cdp.send('Runtime.evaluate', {
                        expression: 'JSON.stringify(globalThis.__cfk || [])',
                        returnByValue: true,
                    }, sid);
                    for (const line of JSON.parse(r?.result?.value || '[]')) {
                        if (seenLines.has(line)) continue;
                        seenLines.add(line);
                        out.beacons.push(line);
                    }
                } catch { /* session gone, or nothing stashed there */ }
            }
        };

        // Persona parity, on about:blank before the station sees anything: an
        // arm off the persona's scale or theme produces readings that are not
        // comparable, and both have already been mistaken for engine defects.
        await pinPersonaMedia(cdp, sessionId);
        await assertPersonaParity(cdp, sessionId, { label: engine });

        await install(sessionId);
        await cdp.send('Page.navigate', { url: target }, sessionId);
        // Fast, because on the Chrome arm the widget's frame is gone a moment
        // after the ticket arrives, and every report still in its global goes
        // with it. At a two-second cadence Chrome's frame reported eight spans
        // and this engine's reported twenty-six -- a difference that was the
        // poll, not the challenge.
        for (let waited = 0; waited < settle; waited += 250) {
            await sleep(250);
            await collect();
        }
        await collect();
        // The engine dumps a context's read log when the context is torn down,
        // and nowhere else. On this engine every frame of the challenge lives
        // in this one target, so closing it is what makes the widget's own
        // realm speak -- and killing the process instead, which is what the
        // finally below does, has produced an empty log every single time.
        if (propReads) {
            for (const id of [...seenTargets, targetId]) {
                try { await cdp.send('Target.closeTarget', { targetId: id }); } catch { /* already gone */ }
            }
            await sleep(2000);
        }
    } finally {
        cdp.close();
        proc.kill('SIGKILL');
        await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
    }
    if (propReads) {
        await sleep(200);
        out.reads = parsePropReads(engineLog);
        out.readContexts = contextsOf(out.reads);
        out.readMembers = [...new Set(out.reads.map((r) => r.member))].length;
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
    const lastPage = out.pageDocs.length ? out.pageDocs[out.pageDocs.length - 1] : null;
    const served = !!lastPage && lastPage.status === 200 && !lastPage.mitigated;
    console.log(`${engine}${headless ? ' (headless)' : ''} knob=${knobName} run ${i + 1}: ` +
        `doc=${out.documents.join('->') || '(none)'} ` +
        `served=${served} ` +
        `ticket=${ticket ? String(ticket.chlOut).slice(0, 10) : '(absent)'} ` +
        `targets=${out.targets} beacons=${out.beacons.length} rounds=[${rounds}]`);
    console.log(`      scripted: ${out.scripted.join(' | ') || '(none)'}`);
    console.log(`      hosts: ${[...new Set(out.challenge.map((c) => c.host))].join(' ') || '(none)'}`);
    if (out.beacons.length) {
        const shown = [...new Set(out.beacons)].slice(0, 6);
        console.log(`      beacons: ${shown.join(' | ')}${out.beacons.length > shown.length ? ' …' : ''}`);
    }
    if (out.reads) {
        console.log(`      reads: ${out.reads.length} keys / ${out.readMembers} members in ` +
            `${out.readContexts.length} realms` +
            out.readContexts.map((c) => `  [${c.context} ${String(c.realm).slice(0, 46)} ${c.members}]`).join(''));
    }
}

if (outPath) {
    await fs.writeFile(outPath, JSON.stringify({ engine, knob: knobName, headless, target, runs: all }, null, 2));
    console.log(`wrote ${outPath}`);
}
