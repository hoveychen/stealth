// Regenerates src/browser/webapi/webrtc/chrome_sdp.zig from the real Chrome on
// this machine.
//
//   node tools/fingerprint/dump-webrtc.mjs [--headed]
//
// Two things are captured, and they have to come from the same browser or they
// would contradict each other:
//
//   1. The media sections of a createOffer() SDP. CreepJS's "sdp capabilities"
//      row is a hash of the codecs, clock rates, fmtp lines and rtcp-fb lines it
//      parses back out of that SDP, so the text has to be Chrome's verbatim —
//      an approximation hashes to something no Chrome ever produced.
//   2. The RTCRtpSender/Receiver.getCapabilities() tables, which are the same
//      codec list reached through a different API. A page that reads both and
//      compares them is the reason they are dumped together.
//
// Only the parts that are constant for a browser build are written out. The
// per-connection random bits — session id, ice-ufrag, ice-pwd, DTLS fingerprint
// — are generated at runtime, so they are stripped here.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const headed = process.argv.includes('--headed');
const PORT = 9463;
const outPath = path.join(repo, 'src/browser/webapi/webrtc/chrome_sdp.zig');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// An offer carrying all three section kinds at once: the audio and video ones
// come from the legacy offerToReceive options, the application one from having
// created a data channel. This is exactly the shape CreepJS asks for.
const PROBE = `(async () => {
  const pc = new RTCPeerConnection();
  pc.createDataChannel('');
  const offer = await pc.createOffer({ offerToReceiveAudio: 1, offerToReceiveVideo: 1 });
  const bare = await new RTCPeerConnection().createOffer();
  pc.close();
  return JSON.stringify({
    version: navigator.userAgent,
    sdp: offer.sdp,
    bare: bare.sdp,
    caps: {
      sender_audio: RTCRtpSender.getCapabilities('audio'),
      sender_video: RTCRtpSender.getCapabilities('video'),
      receiver_audio: RTCRtpReceiver.getCapabilities('audio'),
      receiver_video: RTCRtpReceiver.getCapabilities('video'),
    },
  });
})()`;

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'dump-webrtc-'));
const flags = [`--remote-debugging-port=${PORT}`, `--user-data-dir=${tmp}`, '--no-first-run', '--no-default-browser-check'];
if (!headed) flags.push('--headless=new');
// CDP_ENDPOINT points this at a Chrome we did not spawn -- the Linux container
// from linux-chrome.mjs, whose tables are the ones that belong in the tree now
// that the engine claims Linux. Without it, the only measurable Chrome is the
// macOS one on this machine.
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

const zigString = (s) => '"' + s
    .replace(/\\/g, '\\\\').replace(/"/g, '\\"')
    .replace(/\r/g, '\\r').replace(/\n/g, '\\n') + '"';
// The lines whose values change per connection. They are re-emitted at runtime.
const PER_CONNECTION = /^a=(ice-ufrag|ice-pwd|ice-options|fingerprint|setup):/;

// Splits one m= section into the part before a=mid: and the part after it, with
// the per-connection lines removed. The mid itself is a runtime value (sections
// are numbered by how many the caller actually asked for).
function splitSection(lines) {
    const midIndex = lines.findIndex((l) => l.startsWith('a=mid:'));
    if (midIndex === -1) throw new Error('m= section with no a=mid: line');
    return {
        head: lines.slice(0, midIndex).filter((l) => !PER_CONNECTION.test(l)),
        tail: lines.slice(midIndex + 1),
    };
}

function emitLines(name, lines) {
    if (lines.length === 0) return [`pub const ${name} = "";`, ''];
    const out = [`pub const ${name} =`];
    lines.forEach((l, i) => {
        out.push(`    ${zigString(l + '\r\n')}${i === lines.length - 1 ? ';' : ' ++'}`);
    });
    out.push('');
    return out;
}

function emitCapabilities(name, caps) {
    const out = [`pub const ${name} = Capabilities{`, '    .codecs = &.{'];
    for (const c of caps.codecs) {
        const parts = [`.mime_type = ${zigString(c.mimeType)}`, `.clock_rate = ${c.clockRate}`];
        // Chrome omits these keys entirely rather than reporting null, and a
        // page can tell the difference with `in`. null here means "no key".
        if (c.channels !== undefined) parts.push(`.channels = ${c.channels}`);
        if (c.sdpFmtpLine !== undefined) parts.push(`.sdp_fmtp_line = ${zigString(c.sdpFmtpLine)}`);
        out.push(`        .{ ${parts.join(', ')} },`);
    }
    out.push('    },', '    .header_extensions = &.{');
    for (const h of caps.headerExtensions) {
        out.push(`        .{ .uri = ${zigString(h.uri)}, .direction = ${zigString(h.direction)} },`);
    }
    out.push('    },', '};', '');
    return out;
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
    await sleep(1500);
    const r = await send('Runtime.evaluate', { expression: PROBE, returnByValue: true, awaitPromise: true }, sessionId);
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 500));
    const { version, sdp, bare, caps } = JSON.parse(r.result.value);

    const lines = sdp.split('\r\n').filter((l) => l.length > 0);
    const starts = { audio: -1, video: -1, application: -1 };
    for (const kind of Object.keys(starts)) starts[kind] = lines.findIndex((l) => l.startsWith(`m=${kind} `));
    for (const [kind, at] of Object.entries(starts)) {
        if (at === -1) throw new Error(`Chrome's offer had no m=${kind} section — refusing to write a partial table`);
    }
    const bounds = Object.entries(starts).sort((a, b) => a[1] - b[1]);
    const sections = {};
    bounds.forEach(([kind, at], i) => {
        const end = i + 1 < bounds.length ? bounds[i + 1][1] : lines.length;
        sections[kind] = splitSection(lines.slice(at, end));
    });

    // The session-level preamble, minus the o= line (random) and the BUNDLE
    // line (depends on which sections the caller asked for). BUNDLE does not
    // sit at either end of the preamble, so it is split around where the line
    // appears rather than appended.
    const preambleLines = lines.slice(0, Math.min(...bounds.map(([, at]) => at)))
        .filter((l) => !l.startsWith('v=') && !l.startsWith('o='));
    const bundleAt = preambleLines.findIndex((l) => l.startsWith('a=group:BUNDLE'));
    if (bundleAt === -1) throw new Error('no a=group:BUNDLE line to split the preamble on');
    const preambleHead = preambleLines.slice(0, bundleAt);
    const preambleTail = preambleLines.slice(bundleAt + 1);

    // Sanity: an offer with no m= sections is the preamble with no BUNDLE line.
    const bareBody = bare.split('\r\n').filter((l) => l.length > 0)
        .filter((l) => !l.startsWith('v=') && !l.startsWith('o='));
    if (bareBody.join('\n') !== [...preambleHead, ...preambleTail].join('\n')) {
        throw new Error(`preamble split disagrees with the empty offer:\n${bareBody.join('\n')}`);
    }

    const out = [
        '// GENERATED by tools/fingerprint/dump-webrtc.mjs — do not hand-edit.',
        '//',
        `// Measured from ${version}`,
        '//',
        "// Chrome's createOffer() SDP, split into the pieces that are constant for a",
        '// browser build. RTCPeerConnection.zig reassembles them around the runtime',
        '// values (session id, ice-ufrag, ice-pwd, DTLS fingerprint, mid numbering).',
        '//',
        '// CreepJS parses the codecs, clock rates, fmtp and rtcp-fb lines back out of',
        '// this text and hashes them, so it is carried verbatim rather than rebuilt',
        '// from the capability tables below — the two agree because they were read',
        '// from the same browser in the same run, not because one was derived from',
        '// the other.',
        '',
        'pub const Codec = struct {',
        '    mime_type: []const u8,',
        '    clock_rate: u32,',
        '    // null means Chrome leaves the key off the object entirely, which is',
        '    // distinguishable from a null value.',
        '    channels: ?u32 = null,',
        '    sdp_fmtp_line: ?[]const u8 = null,',
        '};',
        '',
        'pub const HeaderExtension = struct {',
        '    uri: []const u8,',
        '    direction: []const u8,',
        '};',
        '',
        'pub const Capabilities = struct {',
        '    codecs: []const Codec,',
        '    header_extensions: []const HeaderExtension,',
        '};',
        '',
        '// Everything between the o= line and the first m= section. The BUNDLE line',
        '// goes between the two halves, and is left out entirely by an offer that has',
        '// no m= sections at all.',
        ...emitLines('preamble_head', preambleHead),
        ...emitLines('preamble_tail', preambleTail),
        '// Each section is head ++ <the per-connection ICE/DTLS block> ++ a=mid:N ++ tail.',
        ...emitLines('audio_head', sections.audio.head),
        ...emitLines('audio_tail', sections.audio.tail),
        ...emitLines('video_head', sections.video.head),
        ...emitLines('video_tail', sections.video.tail),
        ...emitLines('application_head', sections.application.head),
        ...emitLines('application_tail', sections.application.tail),
        '// RTCRtpSender/Receiver.getCapabilities(). Audio is identical for sender and',
        '// receiver on this build; video is not, so both are carried.',
        ...emitCapabilities('sender_audio', caps.sender_audio),
        ...emitCapabilities('sender_video', caps.sender_video),
        ...emitCapabilities('receiver_audio', caps.receiver_audio),
        ...emitCapabilities('receiver_video', caps.receiver_video),
    ];

    await fs.mkdir(path.dirname(outPath), { recursive: true });
    await fs.writeFile(outPath, out.join('\n'));
    console.log(`wrote ${path.relative(repo, outPath)} — ${Object.keys(sections).length} sections, ` +
        `${caps.sender_audio.codecs.length}+${caps.sender_video.codecs.length} sender codecs`);
} finally {
    try { ws && ws.close(); } catch {}
    proc?.kill('SIGKILL');
    await fs.rm(tmp, { recursive: true, force: true }).catch(() => {});
}
