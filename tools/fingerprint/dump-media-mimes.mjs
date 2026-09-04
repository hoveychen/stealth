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
import { personaScaleFlags } from './cdp.mjs';

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
    'audio/x-mpegurl', 'application/octet-stream',
];

// One member per profile of each parametrised family, because the profile is
// what moves the answer: in video/mp4 avc1 profile 0x64 records and 0x6E does
// not, hvc1 profile 1 records and 2 does not, av01 profile 0 records and 1 does
// not. Levels within a profile agree, so one level each is enough — that is the
// rule codecKey() encodes. The bare four-character names are MediaRecorder's
// "pick a default" spellings and are not parametrised at all.
const CODECS = [
    '1', 'vorbis', 'opus', 'flac', 'mp3', 'mp4a.40.2', 'mp4a.40.5', 'mp4a.69', 'mp4a.6B',
    'mp4a.a5', 'mp4a.a6', 'ac-3', 'ec-3', 'theora', 'speex', 'pcm', 'alaw', 'ulaw',
    'avc1.42E01E', 'avc1.42001E', 'avc1.4D401E', 'avc1.53001E', 'avc1.56001E',
    'avc1.58001E', 'avc1.64001E', 'avc1.6E001E', 'avc1.76001E', 'avc1.7A001E',
    'avc1.80001E', 'avc1.F4001E', 'avc3.42E01E', 'avc1', 'avc3',
    'hvc1.1.6.L93.B0', 'hev1.1.6.L93.B0', 'hvc1.2.4.L120.B0', 'hev1.2.4.L120.B0',
    'hvc1', 'hev1', 'vp8', 'vp9', 'vp09.00.10.08', 'vp09.01.10.08', 'vp09.02.10.10',
    'vp09.03.10.10', 'vp09', 'av01.0.05M.08', 'av01.0.05M.10', 'av01.1.05M.08',
    'av01.2.05M.10', 'av01', 'h264', 'h265', 'mpeg4', 'dvh1.05.07', 'ulpfec',
];

// Types the model must reproduce without having been fitted to them. The
// second group is levels, tiers and bit depths no probe above asked for: they
// are the whole point of parsing a codec string rather than looking it up, and
// they are what Kasada asked hyatt.com's visitors about.
const VALIDATION = [
    'video/mp4; codecs="avc1.42E01E, mp4a.40.2"', 'video/webm; codecs="vp8, vorbis"',
    'video/webm; codecs="vp9, opus"', 'video/ogg; codecs="theora, vorbis"',
    'audio/mp4; codecs="mp4a.40.2, ac-3"', 'video/mp4; codecs="avc1.42E01E, bogus"',
    'video/mp4; codecs="bogus"', 'bogus/type', 'video/mp4; codecs=""', '',
    'video/mp4 ; codecs="avc1.42E01E"', 'video/mp4;codecs=avc1.42E01E',
    'audio/webm; codecs="opus, vorbis"', 'video/webm; codecs="vp8, opus"',

    'video/mp4; codecs="avc1.42c00d"', 'video/mp4; codecs="avc1.640033"',
    'video/mp4; codecs="avc1.4d001f"', 'video/mp4;codecs=avc1.64003E,mp4a.40.2',
    'video/mp4;codecs=avc3.64003E,opus', 'video/mp4;codecs=hvc1.1.6.L186.B0,mp4a.40.2',
    'video/mp4;codecs=hev1.1.6.L186.B0,opus', 'video/mp4;codecs=av01.0.19M.08,mp4a.40.2',
    'video/mp4; codecs="av01.0.19H.08"', 'video/mp4; codecs="av01.0.19M.12"',
    'video/mp4; codecs="hvc1.1.6.L255.B0"', 'video/webm; codecs="vp09.00.51.08"',
    'video/mp4; codecs="avc1.2C001E"', 'video/mp4; codecs="avc1.42E01"',
    'video/mp4; codecs="av01.3.19M.08"', 'video/mp4; codecs="av01.0.19M.09"',
    'audio/x-mpegurl; codecs="avc1.64003E"',
];

// Spellings the model is measured against but knowingly does not reproduce.
// Each is one Chrome code path doing something its neighbour does not, and each
// is written into the generated file's header so it stays a known gap rather
// than an unnoticed one.
//
//   * Case: all three APIs fold case for the container, EXCEPT that
//     MediaRecorder rejects an upper-case mp4 container while accepting an
//     upper-case webm one. The model folds case throughout.
//   * A recognised AVC profile at a level Annex A does not define, and the four
//     profiles Chrome parses but cannot decode: Chrome answers "maybe" to
//     canPlayType, which a set of accepted codecs cannot express.
const KNOWN_DIVERGENCES = [
    'VIDEO/MP4', 'AUDIO/MPEG', 'Video/MP4; codecs="avc1.42E01E"', 'video/MP4',
    'video/mp4; CODECS="avc1.42E01E"', 'video/mp4; codecs="AVC1.42E01E"',
    'AUDIO/WEBM; codecs="opus"',
    'video/mp4; codecs="avc1.42E0FF"', 'video/mp4; codecs="avc1.7A001E"',
    'video/mp4; codecs="avc1.53001E"',
];

const PROBE = `(() => {
  const CONTAINERS = ${JSON.stringify(CONTAINERS)};
  const CODECS = ${JSON.stringify(CODECS)};
  const VALIDATION = ${JSON.stringify([...VALIDATION, ...KNOWN_DIVERGENCES])};
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
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`, '--no-first-run', '--no-default-browser-check', ...personaScaleFlags()];
if (!headed) flags.push('--headless=new');
// CDP_ENDPOINT points this at a Chrome we did not spawn -- the Linux container
// from linux-chrome.mjs. Which of the two belongs in the tree follows
// claimed_platform.zig, and that says macOS, so the default (this machine's
// Chrome) is the right one. It matters here more than in most tables: whether
// MediaRecorder takes HEVC in an mp4 container is whether the platform has a
// hardware encoder for it, and macOS does where the Linux container does not.
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
const proc = ENDPOINT ? null : spawn(CHROME, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
proc?.stdout.resume();
proc?.stderr.resume();

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

// The JS side of src/browser/webapi/media/codec.zig: four codecs pack a profile
// and a level into the string, and Chrome parses those fields rather than
// looking the whole string up, so one measured spelling stands in for every
// other level of the same profile. Keep the two in step — the validation pass
// below is what catches them drifting apart.
const AVC_PROFILES = [0x42, 0x4d, 0x53, 0x56, 0x58, 0x64, 0x6e, 0x76, 0x7a, 0x80, 0xf4];
const AVC_LEVELS = [9, 10, 11, 12, 13, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52, 60, 61, 62];
const VP9_LEVELS = [10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 52, 60, 61, 62];
const DEPTHS = ['08', '10', '12'];

// 'literal' — not one of the four. null — one of them, spelled in a way Chrome's
// parser rejects. Otherwise the key its whole profile shares.
function codecKey(codec) {
    const parametrised = (p) => codec.startsWith(p + '.');
    if (parametrised('avc1') || parametrised('avc3')) {
        const rest = codec.slice(5);
        if (!/^[0-9a-fA-F]{6}$/.test(rest)) return null;
        const id = parseInt(rest, 16);
        const profile = (id >> 16) & 0xff;
        if (!AVC_PROFILES.includes(profile) || !AVC_LEVELS.includes(id & 0xff)) return null;
        return 'avc.' + profile.toString(16).padStart(2, '0');
    }
    if (parametrised('hvc1') || parametrised('hev1')) {
        const f = codec.slice(5).split('.');
        if (f.length < 3 || !f[0].length || f[0].length > 3 || !f[1].length) return null;
        if (f[2].length < 2 || (f[2][0] !== 'L' && f[2][0] !== 'H')) return null;
        return 'hevc.' + f[0];
    }
    if (parametrised('av01')) {
        const f = codec.slice(5).split('.');
        if (f.length < 3 || !/^[0-2]$/.test(f[0])) return null;
        if (!/^\d\d[MH]$/.test(f[1]) || Number(f[1].slice(0, 2)) > 31) return null;
        if (!DEPTHS.includes(f[2])) return null;
        return 'av1.' + f[0];
    }
    if (parametrised('vp09')) {
        const f = codec.slice(5).split('.');
        if (f.length < 3 || !/^0[0-3]$/.test(f[0])) return null;
        if (!/^\d\d$/.test(f[1]) || !VP9_LEVELS.includes(Number(f[1]))) return null;
        if (!DEPTHS.includes(f[2])) return null;
        return 'vp09.' + f[0];
    }
    return 'literal';
}

function accepts(list, codec) {
    const key = codecKey(codec);
    if (key === 'literal') return list.includes(codec);
    if (key === null) return false;
    return list.some((known) => codecKey(known) === key);
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
        play: codecs.every((c) => accepts(entry.play_codecs, c)) ? 'probably' : '',
        mse: codecs.every((c) => accepts(entry.mse_codecs, c)),
        mr: codecs.every((c) => accepts(entry.mr_codecs, c)),
    };
}

try {
    let ver = null;
    for (let i = 0; i < 100; i++) { try { ver = await (await fetch(`${ENDPOINT ?? `http://127.0.0.1:${PORT}`}/json/version`)).json(); break; } catch { await sleep(200); } }
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

    const knownDivergences = new Set(KNOWN_DIVERGENCES);
    const failures = [];
    const divergences = [];
    for (const { t, r: actual } of validation) {
        const got = predict(table, t, emptyType);
        const want = { play: collapseElement(actual, t), mse: actual.mse, mr: actual.mr };
        if (got.play === want.play && got.mse === want.mse && got.mr === want.mr) continue;
        const line = `${JSON.stringify(t)}: this engine ${JSON.stringify(got)} vs Chrome ${JSON.stringify(want)}`;
        (knownDivergences.has(t) ? divergences : failures).push(line);
    }
    if (failures.length) {
        throw new Error('the derived model disagrees with Chrome on:\n  ' + failures.join('\n  '));
    }
    for (const d of divergences) console.log(`  known divergence: ${d}`);

    const entries = [...table.values()].sort((a, b) => (a.container < b.container ? -1 : 1));
    // zig fmt puts no spaces inside a one-element initialiser and spaces inside
    // a longer one, so match it here rather than leave the file failing --check.
    const codecList = (list) => {
        if (list.length === 0) return '&.{}';
        if (list.length === 1) return '&.{' + zigString(list[0]) + '}';
        return '&.{ ' + list.map(zigString).join(', ') + ' }';
    };
    const lines = [
        '// GENERATED by tools/fingerprint/dump-media-mimes.mjs — do not hand-edit.',
        '//',
        `// Measured from ${version}`,
        `// ${entries.length} containers.`,
        '//',
        ...(divergences.length ? [
            '// Known divergences from Chrome, measured by the generator and left',
            '// unmodelled: the first group is one Chrome code path folding case where',
            '// its neighbour does not, the second is Chrome answering "maybe" to a',
            '// codec it parsed but cannot decode, which a set of accepted codecs has',
            '// no way to say:',
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
    proc?.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}
