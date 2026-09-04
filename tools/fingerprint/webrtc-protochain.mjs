// Ground truth for G13: for every RTC* global, the prototype chain, the
// class-side inheritance, the window property descriptor, and the exact
// TypeError text for a few argument shapes.  Runs on about:blank, so it needs
// no proxy.
//
//   node tools/fingerprint/webrtc-protochain.mjs chrome --headed
//   node tools/fingerprint/webrtc-protochain.mjs lightpanda
//
// Env:
//   LP_BIN   path to the lightpanda binary  (default: <repo>/zig-out/bin/lightpanda)
//   CHROME   path to the Chrome binary
//   PORT     CDP port to use, so two runs can go at once
import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { personaScaleFlags } from './cdp.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const { Cdp, newPage, evaluate, sleep } = await import(path.join(HERE, 'cdp.mjs'));

const engine = process.argv[2] ?? 'lightpanda';
const LP = process.env.LP_BIN || path.join(REPO, 'zig-out/bin/lightpanda');
const CHROME = process.env.CHROME ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = Number(process.env.PORT) || Number(process.env.LP_PORT) || 9473;

let proc;
if (engine === 'chrome') {
    const prof = await fs.mkdtemp(path.join(os.tmpdir(), 'webrtc-proto-'));
    const headed = process.argv.includes('--headed');
    proc = spawn(CHROME, [
        ...(headed ? [] : ['--headless=new']), `--remote-debugging-port=${PORT}`,
        `--user-data-dir=${prof}`, '--no-first-run', '--no-default-browser-check', ...personaScaleFlags(),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
} else {
    proc = spawn(LP, ['serve', '--host', '127.0.0.1', '--port', String(PORT)], { stdio: ['ignore', 'pipe', 'pipe'] });
}
const logFile = createWriteStream('/tmp/webrtc-proto-engine.log');
proc.stdout.pipe(logFile);
proc.stderr.pipe(logFile);
await sleep(engine === 'chrome' ? 1500 : 2500);

const cdp = await Cdp.connect(`http://127.0.0.1:${PORT}`);
const { sessionId } = await newPage(cdp);
await cdp.send('Page.navigate', { url: 'about:blank' }, sessionId);
await sleep(500);

const src = `(async () => {
  const out = {};
  const NAMES = Object.getOwnPropertyNames(window).filter((k) => /^(RTC|webkitRTC)/.test(k));
  out.rtcGlobals = NAMES;

  out.chains = {};
  for (const n of NAMES) {
    const C = window[n];
    const chain = [];
    let p = C.prototype ? Object.getPrototypeOf(C.prototype) : null;
    while (p) { chain.push(p.constructor ? p.constructor.name : '?'); p = Object.getPrototypeOf(p); }
    const classSide = Object.getPrototypeOf(C);
    out.chains[n] = {
      protoChain: chain,
      classProto: typeof classSide === 'function' ? classSide.name : String(classSide),
      desc: Object.getOwnPropertyDescriptor(window, n) &&
        (() => { const d = Object.getOwnPropertyDescriptor(window, n);
                 return { writable: d.writable, enumerable: d.enumerable, configurable: d.configurable,
                          isAccessor: !!(d.get || d.set) }; })(),
    };
  }

  // Prototype own-property names *in order* — the order is itself part of the
  // surface a script can hash.
  out.protoKeys = {};
  out.ctorLengths = {};
  for (const n of NAMES) {
    const p = window[n].prototype;
    out.protoKeys[n] = p ? Object.getOwnPropertyNames(p) : null;
    out.ctorLengths[n] = window[n].length;
  }

  out.aliasIdentity = {
    same: window.webkitRTCPeerConnection === window.RTCPeerConnection,
    aliasName: window.webkitRTCPeerConnection && window.webkitRTCPeerConnection.name,
  };

  // Exact TypeError text for a handful of argument shapes we have to reproduce.
  const tryIt = (label, fn) => { try { const v = fn(); out.calls[label] = { ok: true, value: v }; }
                                 catch (e) { out.calls[label] = { ok: false, err: String(e) }; } };
  out.calls = {};
  tryIt('RTCError()', () => new RTCError());
  tryIt('RTCError(dict)', () => { const e = new RTCError({ errorDetail: 'data-channel-failure' });
    return { name: e.name, message: e.message, code: e.code, errorDetail: e.errorDetail,
      sdpLineNumber: e.sdpLineNumber, httpRequestStatusCode: e.httpRequestStatusCode,
      sctpCauseCode: e.sctpCauseCode, receivedAlert: e.receivedAlert, sentAlert: e.sentAlert,
      isDOMException: e instanceof DOMException, str: String(e), stack: typeof e.stack }; });
  tryIt('RTCError(bad detail)', () => new RTCError({ errorDetail: 'nope' }));
  tryIt('RTCError(full)', () => { const e = new RTCError({ errorDetail: 'sdp-syntax-error', sdpLineNumber: 7,
      httpRequestStatusCode: 404, sctpCauseCode: 3, receivedAlert: 40, sentAlert: 41 }, 'boom');
    return { message: e.message, sdpLineNumber: e.sdpLineNumber, httpRequestStatusCode: e.httpRequestStatusCode,
      sctpCauseCode: e.sctpCauseCode, receivedAlert: e.receivedAlert, sentAlert: e.sentAlert }; });

  tryIt('RTCErrorEvent(1)', () => new RTCErrorEvent('e'));
  tryIt('RTCErrorEvent(2)', () => { const e = new RTCErrorEvent('e', { error: new RTCError({ errorDetail: 'dtls-failure' }) });
    return { type: e.type, errName: e.error && e.error.name, bubbles: e.bubbles, cancelable: e.cancelable }; });
  tryIt('RTCErrorEvent(no error)', () => new RTCErrorEvent('e', {}));

  tryIt('RTCTrackEvent(1)', () => new RTCTrackEvent('track'));
  tryIt('RTCTrackEvent(empty dict)', () => new RTCTrackEvent('track', {}));

  tryIt('RTCDataChannelEvent(1)', () => new RTCDataChannelEvent('datachannel'));
  tryIt('RTCDataChannelEvent(empty)', () => new RTCDataChannelEvent('datachannel', {}));
  tryIt('RTCDataChannelEvent(real)', () => { const pc = new RTCPeerConnection();
    const dc = pc.createDataChannel('x');
    const e = new RTCDataChannelEvent('datachannel', { channel: dc });
    const r = { type: e.type, label: e.channel.label, bubbles: e.bubbles }; pc.close(); return r; });

  tryIt('RTCPeerConnectionIceErrorEvent(1)', () => new RTCPeerConnectionIceErrorEvent('e'));
  tryIt('RTCPeerConnectionIceErrorEvent(empty)', () => new RTCPeerConnectionIceErrorEvent('e', {}));
  tryIt('RTCPeerConnectionIceErrorEvent(2)', () => { const e = new RTCPeerConnectionIceErrorEvent('icecandidateerror',
      { errorCode: 701 });
    return { type: e.type, address: e.address, port: e.port, hostCandidate: e.hostCandidate, url: e.url,
      errorCode: e.errorCode, errorText: e.errorText }; });

  tryIt('RTCPeerConnectionIceErrorEvent(addr)', () => { const e = new RTCPeerConnectionIceErrorEvent(
      'icecandidateerror', { errorCode: 701, address: '1.2.3.4', port: 5000, url: 'stun:x', errorText: 'nope' });
    return { address: e.address, port: e.port, hostCandidate: e.hostCandidate, url: e.url,
      errorCode: e.errorCode, errorText: e.errorText }; });
  tryIt('RTCPeerConnectionIceErrorEvent(addr no port)', () => { const e = new RTCPeerConnectionIceErrorEvent(
      'icecandidateerror', { errorCode: 701, address: '1.2.3.4' });
    return { address: e.address, port: e.port, hostCandidate: e.hostCandidate }; });

  tryIt('RTCDTMFToneChangeEvent(1)', () => new RTCDTMFToneChangeEvent('tonechange'));
  tryIt('RTCDTMFToneChangeEvent(empty)', () => { const e = new RTCDTMFToneChangeEvent('tonechange', {});
    return { tone: e.tone }; });

  tryIt('RTCEncodedAudioFrame(1)', () => new RTCEncodedAudioFrame());
  tryIt('RTCEncodedAudioFrame(junk)', () => new RTCEncodedAudioFrame({}));
  tryIt('RTCEncodedVideoFrame(junk)', () => new RTCEncodedVideoFrame({}));
  tryIt('RTCRtpScriptTransform()', () => new RTCRtpScriptTransform());
  tryIt('RTCRtpScriptTransform(junk)', () => new RTCRtpScriptTransform({}));
  tryIt('RTCCertificate()', () => new RTCCertificate());
  tryIt('RTCRtpTransceiver()', () => new RTCRtpTransceiver());

  // Symbol.toStringTag presence on the prototypes we are about to add.
  out.tags = {};
  for (const n of NAMES) {
    const p = window[n].prototype;
    const d = p && Object.getOwnPropertyDescriptor(p, Symbol.toStringTag);
    out.tags[n] = d ? { value: d.value, writable: d.writable, enumerable: d.enumerable, configurable: d.configurable }
                    : null;
  }

  // How the transceiver/transport getters read off a live pc, so the classes
  // are not pure vapour if anything ever does reach them.
  try {
    const pc = new RTCPeerConnection();
    const t = pc.addTransceiver('audio');
    out.liveTransceiver = { mid: t.mid, direction: t.direction, currentDirection: t.currentDirection,
      stopped: t.stopped, senderCtor: t.sender.constructor.name, receiverCtor: t.receiver.constructor.name,
      transportOnSender: t.sender.transport, dtmfCtor: t.sender.dtmf && t.sender.dtmf.constructor.name,
      headerExts: t.getHeaderExtensionsToNegotiate().slice(0, 2),
      negotiated: t.getNegotiatedHeaderExtensions() };
    pc.close();
  } catch (e) { out.liveTransceiverErr = String(e); }

  out.workerRtc = await new Promise((resolve) => {
    try {
      const blob = new Blob(['self.postMessage(Object.getOwnPropertyNames(self).filter(k=>/^RTC/.test(k)))'],
        { type: 'text/javascript' });
      const w = new Worker(URL.createObjectURL(blob));
      w.onmessage = (e) => { resolve(e.data); w.terminate(); };
      setTimeout(() => resolve('timeout'), 3000);
    } catch (e) { resolve(String(e)); }
  });

  return out;
})()`;

const out = await evaluate(cdp, sessionId, src, { awaitPromise: true });
await fs.writeFile(`/tmp/webrtc-protochain-${engine}.json`, JSON.stringify(out, null, 1));
console.log(`wrote /tmp/webrtc-protochain-${engine}.json`);

cdp.close();
proc.kill('SIGKILL');
