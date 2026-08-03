// Regenerates src/browser/webapi/media/chrome_mimes.zig from the real Chrome on
// this machine.
//
//   node tools/fingerprint/dump-media-mimes.mjs [--headed]
//
// Three APIs answer "can you play this?" and fingerprinting scripts read all
// three, so all three are measured together: HTMLMediaElement.canPlayType(),
// MediaSource.isTypeSupported() and MediaRecorder.isTypeSupported(). CreepJS
// asks for twelve types across all of them and renders the grid.
//
// The answers are not derivable from each other. audio/mpeg is "probably" to
// canPlayType and true to MediaSource but false to MediaRecorder; video/webm is
// only "maybe" bare but "probably" with a codec; MediaRecorder takes opus in a
// webm container but not vorbis. So the table carries, per container, the bare
// answer for each API plus the set of codecs each API accepts inside it.
//
// The script measures single codecs and then CHECKS the derived model against
// multi-codec and edge-case types it did not learn from. A mismatch fails the
// run rather than writing a table that quietly disagrees with the browser.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const headed = process.argv.includes('--headed');
const PORT = 9464;
const outPath = path.join(repo, 'src/browser/webapi/media/chrome_mimes.zig');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Containers worth answering: the union of what the public fingerprinting
// suites probe (CreepJS, fp-collect, arkenfox TZP) plus the ordinary ones.
const CONTAINERS = [
    'audio/ogg', 'audio/mpeg', 'audio/mpegurl', 'audio/mp4', 'audio/x-m4a', 'audio/aac',
    'audio/wav', 'audio/wave', 'audio/x-wav', 'audio/x-pn-wav', 'audio/vnd.wave',
    'audio/webm', 'audio/flac', 'audio/x-flac', 'audio/mp3', 'audio/basic', 'audio/midi',
    'audio/x-midi', 'audio/3gpp', 'audio/3gpp2', 'audio/opus', 'audio/x-ms-wma',
    'video/ogg', 'video/mp4', 'video/webm', 'video/quicktime', 'video/x-matroska',
    'video/x-msvideo', 'video/avi', 'video/3gpp', 'video/3gpp2', 'video/x-m4v',
    'video/mpeg', 'video/x-flv', 'video/mp2t', 'video/x-ms-wmv',
    'application/ogg', 'application/x-mpegurl', 'application/vnd.apple.mpegurl',
    'application/octet-stream',
];

const CODECS = [
    '1', 'vorbis', 'opus', 'flac', 'mp3', 'mp4a.40.2', 'mp4a.40.5', 'mp4a.69', 'mp4a.6B',
    'mp4a.a5', 'mp4a.a6', 'ac-3', 'ec-3', 'theora', 'speex', 'pcm', 'alaw', 'ulaw',
    'avc1.42E01E', 'avc1.42001E', 'avc1.4D401E', 'avc1.64001E', 'avc3.42E01E',
    'hvc1.1.6.L93.B0', 'hev1.1.6.L93.B0', 'vp8', 'vp9', 'vp09.00.10.08', 'vp09.02.10.10',
    'av01.0.05M.08', 'av01.0.05M.10', 'h264', 'h265', 'mpeg4', 'dvh1.05.07', 'ulpfec',
];

// Types the model must reproduce without having been fitted to them.
const VALIDATION = [
    'video/mp4; codecs="avc1.42E01E, mp4a.40.2"', 'video/webm; codecs="vp8, vorbis"',
    'video/webm; codecs="vp9, opus"', 'video/ogg; codecs="theora, vorbis"',
    'audio/mp4; codecs="mp4a.40.2, ac-3"', 'video/mp4; codecs="avc1.42E01E, bogus"',
    'video/mp4; codecs="bogus"', 'bogus/type', 'video/mp4; codecs=""', '',
    'video/mp4 ; codecs="avc1.42E01E"', 'video/mp4;codecs=avc1.42E01E',
    'audio/webm; codecs="opus, vorbis"', 'video/webm; codecs="vp8, opus"',
];

// Case-variant spellings. All three APIs fold case for the container, EXCEPT
// that MediaRecorder rejects an upper-case mp4 container while accepting an
// upper-case webm one. That is one Chrome code path being case-sensitive where
// its neighbour is not; rather than encode the oddity, the model folds case
// throughout and any resulting divergence is measured and reported below, so it
// is a known gap rather than an unnoticed one.
const CASE_PROBES = [
    'VIDEO/MP4', 'AUDIO/MPEG', 'Video/MP4; codecs="avc1.42E01E"', 'video/MP4',
    'video/mp4; CODECS="avc1.42E01E"', 'video/mp4; codecs="AVC1.42E01E"',
    'AUDIO/WEBM; codecs="opus"',
];

const PROBE = `(() => {
  const CONTAINERS = ${JSON.stringify(CONTAINERS)};
  const CODECS = ${JSON.stringify(CODECS)};
  const VALIDATION = ${JSON.stringify([...VALIDATION, ...CASE_PROBES])};
  const v = document.createElement('video');
  const a = new Audio();
  const ask = (t) => ({
    audio: a.canPlayType(t),
    video: v.canPlayType(t),
    mse: MediaSource.isTypeSupported(t),
    mr: MediaRecorder.isTypeSupported(t),
  });
  const containers = CONTAINERS.map((c) => ({
    container: c,
    bare: ask(c),
    codecs: CODECS.map((k) => ({ codec: k, r: ask(c + '; codecs="' + k + '"') })),
  }));
  return JSON.stringify({
    version: navigator.userAgent,
    containers,
    validation: VALIDATION.map((t) => ({ t, r: ask(t) })),
  });
})()`;

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-mimes-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`, '--no-first-run', '--no-default-browser-check'];
if (!headed) flags.push('--headless=new');
const proc = spawn(CHROME, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
proc.stdout.resume();
proc.stderr.resume();

const pending = new Map();
let id = 1, ws;
const send = (method, params, sessionId) =>
    new Promise((resolve, reject) => {
        const i = id++;
        pending.set(i, { resolve, reject });
        ws.send(JSON.stringify({ id: i, method, params, sessionId }));
        setTimeout(() => { if (pending.delete(i)) reject(new Error(`timeout ${method}`)); }, 60000);
    });

const zigString = (s) => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

// Chrome answers canPlayType identically on an <audio> and a <video> element;
// the model relies on that, so it is asserted rather than assumed.
function collapseElement(r, where) {
    if (r.audio !== r.video) {
        throw new Error(`canPlayType differs between audio and video for ${where}: ${r.audio} vs ${r.video}`);
    }
    return r.audio;
}

// The model: a type resolves to its container's bare answer when no codecs are
// given, and otherwise every listed codec must be in that container's accepted
// set for that API.
function predict(table, type, emptyType) {
    const trimmed = type.trim();
    if (trimmed.length === 0) return { play: '', mse: emptyType.mse, mr: emptyType.mr };

    const semi = trimmed.indexOf(';');
    const container = (semi === -1 ? trimmed : trimmed.slice(0, semi)).trim().toLowerCase();
    const entry = table.get(container);
    if (!entry) return { play: '', mse: false, mr: false };

    let codecs = [];
    if (semi !== -1) {
        const rest = trimmed.slice(semi + 1).trim();
        const m = /^codecs\s*=\s*"?([^"]*)"?$/i.exec(rest);
        if (m) codecs = m[1].split(',').map((c) => c.trim()).filter((c) => c.length > 0);
    }
    if (codecs.length === 0) return entry.bare;
    return {
        play: codecs.every((c) => entry.play_codecs.includes(c)) ? 'probably' : '',
        mse: codecs.every((c) => entry.mse_codecs.includes(c)),
        mr: codecs.every((c) => entry.mr_codecs.includes(c)),
    };
}

try {
    let ver = null;
    for (let i = 0; i < 100; i++) { try { ver = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); } }
    if (!ver) throw new Error('Chrome CDP never came up');
    ws = new WebSocket(ver.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.addEventListener('open', res); ws.addEventListener('error', rej); });
    ws.addEventListener('message', (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id && pending.has(m.id)) { const { resolve, reject } = pending.get(m.id); pending.delete(m.id); m.error ? reject(new Error(m.error.message)) : resolve(m.result); }
    });
    const { targetId } = await send('Target.createTarget', { url: 'https://example.com/' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    await send('Runtime.enable', {}, sessionId);
    await sleep(1200);
    const r = await send('Runtime.evaluate', { expression: PROBE, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 500));
    const { version, containers, validation } = JSON.parse(r.result.value);

    const table = new Map();
    for (const c of containers) {
        table.set(c.container, {
            container: c.container,
            bare: { play: collapseElement(c.bare, c.container), mse: c.bare.mse, mr: c.bare.mr },
            play_codecs: c.codecs.filter((k) => collapseElement(k.r, `${c.container};${k.codec}`) === 'probably').map((k) => k.codec),
            mse_codecs: c.codecs.filter((k) => k.r.mse).map((k) => k.codec),
            mr_codecs: c.codecs.filter((k) => k.r.mr).map((k) => k.codec),
        });
    }

    // A container nothing can play, with no codec accepted anywhere, is dead
    // weight in the table.
    for (const [name, e] of [...table]) {
        if (e.bare.play === '' && !e.bare.mse && !e.bare.mr &&
            !e.play_codecs.length && !e.mse_codecs.length && !e.mr_codecs.length) {
            table.delete(name);
        }
    }

    const emptyMeasured = validation.find((x) => x.t === '');
    const emptyType = { mse: emptyMeasured.r.mse, mr: emptyMeasured.r.mr };

    const caseProbes = new Set(CASE_PROBES);
    const failures = [];
    const divergences = [];
    for (const { t, r: actual } of validation) {
        const got = predict(table, t, emptyType);
        const want = { play: collapseElement(actual, t), mse: actual.mse, mr: actual.mr };
        if (got.play === want.play && got.mse === want.mse && got.mr === want.mr) continue;
        const line = `${JSON.stringify(t)}: this engine ${JSON.stringify(got)} vs Chrome ${JSON.stringify(want)}`;
        (caseProbes.has(t) ? divergences : failures).push(line);
    }
    if (failures.length) {
        throw new Error('the derived model disagrees with Chrome on:\n  ' + failures.join('\n  '));
    }
    for (const d of divergences) console.log(`  known divergence: ${d}`);

    const entries = [...table.values()].sort((a, b) => (a.container < b.container ? -1 : 1));
    const codecList = (list) => (list.length === 0 ? '&.{}' : '&.{ ' + list.map(zigString).join(', ') + ' }');
    const lines = [
        '// GENERATED by tools/fingerprint/dump-media-mimes.mjs — do not hand-edit.',
        '//',
        `// Measured from ${version}`,
        `// ${entries.length} containers.`,
        '//',
        ...(divergences.length ? [
            '// Known divergences from Chrome, measured by the generator and left',
            '// unmodelled because each is one Chrome code path folding case where its',
            '// neighbour does not:',
            ...divergences.map((d) => `//   ${d}`),
            '//',
        ] : []),
        "// What Chrome answers to canPlayType(), MediaSource.isTypeSupported() and",
        '// MediaRecorder.isTypeSupported(). The three disagree with each other often',
        '// enough that all three are carried per container: audio/mpeg plays and can be',
        '// demuxed by MSE but cannot be recorded, video/webm is only "maybe" until a',
        '// codec is named, and MediaRecorder takes opus in webm where MSE also takes',
        '// vorbis.',
        '//',
        '// `bare_*` is the answer with no codecs parameter. `*_codecs` is the set each',
        '// API accepts inside that container; a type naming codecs is supported only if',
        '// every one of them is in the set. The generator verifies that rule against',
        '// multi-codec types it did not learn from before writing this file.',
        '',
        'pub const PlayResponse = enum {',
        '    no,',
        '    maybe,',
        '    probably,',
        '',
        '    pub fn toString(self: PlayResponse) []const u8 {',
        '        return switch (self) {',
        '            .no => "",',
        '            .maybe => "maybe",',
        '            .probably => "probably",',
        '        };',
        '    }',
        '};',
        '',
        'pub const Container = struct {',
        '    name: []const u8,',
        '    bare_play: PlayResponse,',
        '    bare_mse: bool,',
        '    bare_mr: bool,',
        '    play_codecs: []const []const u8,',
        '    mse_codecs: []const []const u8,',
        '    mr_codecs: []const []const u8,',
        '};',
        '',
        '// Sorted by name so a lookup can binary-search if it ever needs to.',
        'pub const containers = [_]Container{',
    ];
    for (const e of entries) {
        lines.push(`    .{`);
        lines.push(`        .name = ${zigString(e.container)},`);
        lines.push(`        .bare_play = .${e.bare.play === '' ? 'no' : e.bare.play},`);
        lines.push(`        .bare_mse = ${e.bare.mse},`);
        lines.push(`        .bare_mr = ${e.bare.mr},`);
        lines.push(`        .play_codecs = ${codecList(e.play_codecs)},`);
        lines.push(`        .mse_codecs = ${codecList(e.mse_codecs)},`);
        lines.push(`        .mr_codecs = ${codecList(e.mr_codecs)},`);
        lines.push(`    },`);
    }
    lines.push('};', '');

    // MediaRecorder answers true to the empty string — it means "your default",
    // not "nothing" — while MediaSource answers false. Neither follows from the
    // table, so both are carried explicitly.
    const empty = emptyMeasured;
    lines.push('// Measured: MediaRecorder reads the empty string as "pick a default" and');
    lines.push('// answers true, where MediaSource answers false.');
    lines.push(`pub const empty_type_mse = ${empty.r.mse};`);
    lines.push(`pub const empty_type_mr = ${empty.r.mr};`);
    lines.push('');

    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, lines.join('\n'));
    console.log(`wrote ${path.relative(repo, outPath)} — ${entries.length} containers, ` +
        `${validation.length} validation types reproduced`);
} finally {
    try { ws && ws.close(); } catch {}
    proc.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}
