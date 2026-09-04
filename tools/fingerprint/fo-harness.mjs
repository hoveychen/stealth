// Getting a recorder in front of the widget's own code, on the real station.
//
// This is fo-plaintext.mjs's machinery with the recorder taken out of it. The
// recorder is the part that changes per question -- which funnels to wrap, what
// to write down -- and everything around it is the same fight every time:
//
//   * the widget is a cross-origin child with a target of its own under
//     Chrome's site isolation, so a main-frame evaluate cannot reach it and the
//     child has to be armed through its own session before its document runs;
//   * a session that is not paused on start has already run its first document
//     by the time the script lands, so the pause is what buys the window --
//     but a *worker* session paused on start deadlocks if anything is sent
//     ahead of its resume, so workers are resumed first and armed from the
//     document realm instead;
//   * records come back over the console, because a cross-origin realm has no
//     other channel to a driver that is not attached to it.
//
// All of that was measured the hard way (see fo-plaintext.mjs's header and
// worker-arm-probe.mjs) and none of it is audio- or plaintext-specific, so a
// second question does not get to relearn it.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, assertPersonaParity, personaScaleFlags, pinPersonaMedia, sleep } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '../..');

export const arg = (n, d) => {
    const i = process.argv.indexOf(n);
    return i < 0 ? d : process.argv[i + 1];
};
export const has = (n) => process.argv.includes(n);

export const CHROME = process.env.CHROME
    ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const LIGHTPANDA = process.env.LP_BIN ?? path.join(REPO, 'zig-out/bin/lightpanda');

/// The user agent a *headed* Chrome would send, read off a throwaway launch.
/// Headless Chrome says `HeadlessChrome` in its own, which is a tell of its own
/// on a station that reads it.
export async function headedUserAgent(port) {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-ua-'));
    const probe = spawn(CHROME, [
        `--remote-debugging-port=${port}`,
        `--user-data-dir=${dir}`,
        '--no-first-run', '--no-default-browser-check', '--headless=new',
    ], { stdio: 'ignore' });
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const { 'User-Agent': ua } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
                if (ua) return ua.replace('HeadlessChrome', 'Chrome');
            } catch { /* not up yet */ }
            await sleep(200);
        }
        throw new Error('could not read the browser user agent for --headed-ua');
    } finally {
        probe.kill('SIGKILL');
        await fs.rm(dir, { recursive: true, force: true }).catch(() => { });
        await sleep(300);
    }
}

/// Drives one arm of a sitting: launches the engine, arms every realm it can
/// reach with `recorder`, navigates, waits, and hands back what the recorder
/// said.
///
/// `state` is the caller's own object and is filled in place, so a caller can
/// seed it with whatever it wants written beside the records. `onMessage` sees
/// every CDP message the harness does not consume itself, which is where a
/// caller puts its own network or target bookkeeping.
export async function runTrace({
    engine, url, settleMs, port, recorder, mark,
    userAgentOverride = null, logLevel = 'info', state = {}, onMessage = null,
}) {
    state.records ??= [];   // one per instrumented call, in arrival order
    state.blobs ??= [];     // blob source text, stitched back from console chunks
    state.realms ??= [];    // which sessions got the recorder, and whether it took
    state.console ??= [];
    state.exceptions ??= [];

    let profile;
    const proc = engine === 'chrome'
        ? spawn(CHROME, [
            `--remote-debugging-port=${port}`,
            `--user-data-dir=${profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-pt-'))}`,
            '--no-first-run', '--no-default-browser-check', '--window-size=1920,1080',
            '--headless=new',
            ...personaScaleFlags(),
            ...(userAgentOverride ? [`--user-agent=${userAgentOverride}`] : []),
        ], { stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(LIGHTPANDA, ['serve', '--host', '127.0.0.1', '--port', String(port),
            '--log_level', logLevel], { stdio: ['ignore', 'pipe', 'pipe'] });

    const engineLog = [];
    proc.stdout.on('data', (d) => engineLog.push(String(d)));
    proc.stderr.on('data', (d) => engineLog.push(String(d)));

    let cdp = null;
    try {
        for (let i = 0; i < 100; i++) {
            try {
                const r = await fetch(`http://127.0.0.1:${port}/json/version`);
                if (r.ok) { state.version = await r.json(); break; }
            } catch { /* not up */ }
            await sleep(250);
        }

        cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const { sessionId: pageSession } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });

        // A child target must be armed before its document runs, and the only
        // hook early enough is addScriptToEvaluateOnNewDocument on the child's
        // own session -- which does not exist until the child is attached.
        // Pausing new targets on start is what buys the window in between.
        //
        // Workers are excluded from the pause rather than from the run: a
        // paused worker's session queue is blocked head-on by anything sent
        // ahead of the resume, so a worker session is resumed first and only
        // then asked anything. Nothing is installed into it either way; it is
        // reached from the document realm by the caller's own recorder.
        async function arm(sid, why, type) {
            const rec = { session: sid ?? 'page', why, type, installed: false, resumed: false };
            state.realms.push(rec);
            if (type && /worker/.test(type)) {
                rec.worker = true;
                await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
                    .then(() => { rec.resumed = true; }).catch(() => { });
                await cdp.send('Network.enable', { maxPostDataSize: 1048576 }, sid).catch(() => { });
                return;
            }
            await cdp.send('Runtime.enable', undefined, sid).catch(() => { });
            await cdp.send('Page.enable', undefined, sid).catch(() => { });
            try {
                await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: recorder }, sid);
                rec.installed = true;
            } catch (err) { rec.err = String(err.message ?? err); }
            await cdp.send('Target.setAutoAttach',
                { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sid).catch(() => { });
            await cdp.send('Network.enable', { maxPostDataSize: 1048576 }, sid).catch(() => { });
            // Whether or not the pause took, releasing is harmless.
            await cdp.send('Runtime.runIfWaitingForDebugger', undefined, sid)
                .then(() => { rec.resumed = true; }).catch(() => { });
        }

        cdp.on((msg) => {
            const p = msg.params ?? {};
            if (msg.method === 'Target.attachedToTarget' && p.sessionId) {
                arm(p.sessionId, p.targetInfo?.url ?? '?', p.targetInfo?.type ?? '?').catch(() => { });
                return;
            }
            if (msg.method === 'Runtime.consoleAPICalled') {
                const text = (p.args ?? []).map((a) => a.value ?? a.description ?? '').join(' ');
                if (text.startsWith(mark)) {
                    let rec;
                    try { rec = JSON.parse(text.slice(mark.length)); } catch { /* truncated */ }
                    if (!rec) {
                        state.records.push({ session: msg.sessionId ?? 'page', unparsed: text.length });
                    } else if (rec.k === 'blob') {
                        state.blobs.push({ session: msg.sessionId ?? 'page', id: rec.id, n: rec.n, type: rec.type, src: '' });
                    } else if (rec.k === 'blob.part') {
                        // Parts arrive in emit order, so appending is enough;
                        // `at` is kept only so a gap would be visible.
                        const b = state.blobs.find((x) => x.id === rec.id);
                        if (b) { if (b.src.length !== rec.at) b.gapAt = rec.at; b.src += rec.src; }
                    } else {
                        state.records.push({ session: msg.sessionId ?? 'page', ...rec });
                    }
                } else if (state.console.length < 200) {
                    state.console.push(`${p.type}: ${text.slice(0, 200)}`);
                }
                return;
            }
            if (msg.method === 'Runtime.exceptionThrown' && state.exceptions.length < 60) {
                state.exceptions.push((p.exceptionDetails?.exception?.description
                    ?? p.exceptionDetails?.text ?? '').split('\n')[0].slice(0, 200));
                return;
            }
            onMessage?.(msg, state);
        });

        // On about:blank, before the station sees anything: pin the media
        // features a launch flag cannot carry, then read every persona axis
        // back and refuse to continue on an arm that is not on them. A reading
        // taken at the wrong scale or the wrong theme is not comparable, and
        // both have already been mistaken for defects in this engine.
        await pinPersonaMedia(cdp, pageSession);
        state.personaAxes = await assertPersonaParity(cdp, pageSession, { label: engine });

        await arm(pageSession, 'page', 'page');
        await cdp.send('Page.navigate', { url }, pageSession);
        await sleep(settleMs);

        try {
            state.final = await cdp.send('Runtime.evaluate', {
                expression: `JSON.stringify({
                    title: document.title,
                    text: (document.body ? document.body.innerText : '').slice(0, 200),
                })`,
                returnByValue: true,
            }, pageSession).then((r) => JSON.parse(r.result?.value ?? 'null'));
        } catch (err) { state.final = { err: String(err.message ?? err) }; }
    } catch (err) {
        state.error = String(err.message ?? err);
    } finally {
        cdp?.close();
        proc.kill('SIGKILL');
        if (profile) await fs.rm(profile, { recursive: true, force: true }).catch(() => { });
    }
    state.engineLog = engineLog.join('').slice(-4000);
    return state;
}

/// The run beside its own artefacts: blob sources are written as source next to
/// the json rather than as json strings inside it, because a 30 KB program that
/// is *nearly* the same on both arms is the interesting case and a JSON string
/// of one is not readable.
export async function writeRun(out, state) {
    const abs = path.resolve(REPO, out.startsWith('tools/') ? out : path.join('tools/fingerprint', out));
    await fs.mkdir(path.dirname(abs), { recursive: true });
    const stem = abs.replace(/\.json$/, '');
    for (const b of state.blobs ?? []) {
        if (!b.src) continue;
        const file = `${stem}-${b.id}.js`;
        await fs.writeFile(file, b.src);
        console.log(`wrote ${file} (${b.src.length} bytes)`);
    }
    await fs.writeFile(abs, JSON.stringify(
        { ...state, blobs: (state.blobs ?? []).map(({ src, ...b }) => ({ ...b, srcLen: src.length })) }, null, 1));
    console.log(`wrote ${abs}`);
    return abs;
}
