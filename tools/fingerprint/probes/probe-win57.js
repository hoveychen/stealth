// Batch 19 / P1 discovery: the EME + Media Source + media-capture family.
//
// The CreepJS missing-key table stops at Chrome 115, so it is a floor, not the
// scope. This dumps the whole family off a live Chrome: which names exist, the
// exact prototype own-property order, statics, arity, and the prototype chain.
// Run against Chrome first to set scope, then against lightpanda to diff.
(async () => {
  const s = (f) => { try { const v = f(); return v === undefined ? 'undefined' : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  const out = {};

  const NAMES = [
    // EME
    'MediaKeys', 'MediaKeySession', 'MediaKeyStatusMap', 'MediaKeySystemAccess',
    'MediaKeyMessageEvent', 'MediaEncryptedEvent', 'MediaKeysPolicy',
    // MSE
    'MediaSource', 'SourceBuffer', 'SourceBufferList', 'MediaSourceHandle',
    'ManagedMediaSource', 'ManagedSourceBuffer',
    // Media Session
    'MediaSession', 'MediaMetadata',
    // Breakout box
    'MediaStreamTrackGenerator', 'MediaStreamTrackProcessor',
    // capture / misc
    'ImageCapture', 'PhotoCapabilities', 'CanvasCaptureMediaStreamTrack',
    'VideoPlaybackQuality', 'RemotePlayback',
    'MediaStream', 'MediaStreamTrack', 'MediaRecorder',
  ];

  const shape = (name) => {
    const C = globalThis[name];
    if (typeof C === 'undefined') return 'ABSENT';
    const r = {};
    r.typeof = typeof C;
    r.arity = s(() => C.length);
    r.name = s(() => C.name);
    r.statics = s(() => Object.getOwnPropertyNames(C).filter((k) => !['length', 'name', 'prototype'].includes(k)).join(' '));
    r.ctorProtoOf = s(() => Object.getPrototypeOf(C).name || String(Object.getPrototypeOf(C)));
    const P = C.prototype;
    if (!P) { r.prototype = 'none'; return r; }
    r.protoOf = s(() => {
      const pp = Object.getPrototypeOf(P);
      return pp === null ? 'null' : (pp === Object.prototype ? 'Object.prototype' : Object.prototype.toString.call(pp));
    });
    r.brand = s(() => String(P[Symbol.toStringTag]));
    // Declaration order matters: JsApi member order is the JS own-property order.
    r.protoOwn = s(() => Object.getOwnPropertyNames(P).join(' '));
    r.protoSymbols = s(() => Object.getOwnPropertySymbols(P).map(String).join(' '));
    r.desc = {};
    for (const k of Object.getOwnPropertyNames(P)) {
      const d = Object.getOwnPropertyDescriptor(P, k);
      if (d.get || d.set) r.desc[k] = `accessor g=${!!d.get} s=${!!d.set} e=${d.enumerable} c=${d.configurable}`;
      else r.desc[k] = `value ${typeof d.value}${typeof d.value === 'function' ? '/' + d.value.length : ''} w=${d.writable} e=${d.enumerable} c=${d.configurable}`;
    }
    r.newNoArgs = s(() => { const o = new C(); return Object.prototype.toString.call(o); });
    return r;
  };

  out.shapes = {};
  for (const n of NAMES) out.shapes[n] = shape(n);

  // Entry points that hand these objects out.
  const video = document.createElement('video');
  const canvas = Object.assign(document.createElement('canvas'), { width: 32, height: 32 });
  canvas.getContext('2d').fillRect(0, 0, 8, 8);

  out.entry = {
    navRequestMKSA: s(() => typeof navigator.requestMediaKeySystemAccess),
    navRequestMKSAArity: s(() => navigator.requestMediaKeySystemAccess.length),
    videoMediaKeys: s(() => String(video.mediaKeys)),
    videoSetMediaKeys: s(() => typeof video.setMediaKeys),
    videoOnEncrypted: s(() => String(video.onencrypted)),
    videoOnWaitingForKey: s(() => String(video.onwaitingforkey)),
    videoRemote: s(() => Object.prototype.toString.call(video.remote)),
    videoGetVideoPlaybackQuality: s(() => Object.prototype.toString.call(video.getVideoPlaybackQuality())),
    vpqFields: s(() => { const q = video.getVideoPlaybackQuality(); return Object.getOwnPropertyNames(Object.getPrototypeOf(q)).map((k) => `${k}=${String(q[k])}`).join(' '); }),
    canvasCaptureStream: s(() => Object.prototype.toString.call(canvas.captureStream())),
    canvasCaptureTrack: s(() => Object.prototype.toString.call(canvas.captureStream().getVideoTracks()[0])),
    mediaSessionMetadata: s(() => String(navigator.mediaSession.metadata)),
  };

  // MediaSource -> SourceBuffer, the only path to a live SourceBuffer.
  const sect = async (fn) => { try { return await fn(); } catch (e) { return `SECTION THREW ${e.name}: ${e.message}`; } };

  out.mse = await sect(async () => {
    const r = {};
    if (typeof MediaSource === 'undefined') return 'ABSENT';
    const ms = new MediaSource();
    r.detachedReadyState = s(() => ms.readyState);
    r.detachedSourceBuffers = s(() => Object.prototype.toString.call(ms.sourceBuffers));
    r.sbListProtoOwn = s(() => Object.getOwnPropertyNames(Object.getPrototypeOf(ms.sourceBuffers)).join(' '));
    r.sbListLength = s(() => ms.sourceBuffers.length);
    r.sbListIndexed = s(() => String(ms.sourceBuffers[0]));
    r.detachedAdd = s(() => ms.addSourceBuffer('video/mp4; codecs="avc1.42E01E"'));
    r.handle = s(() => Object.prototype.toString.call(ms.handle));
    video.src = URL.createObjectURL(ms);
    const opened = await new Promise((res) => {
      const t = setTimeout(() => res('TIMEOUT'), 600);
      ms.addEventListener('sourceopen', () => { clearTimeout(t); res('open'); });
    });
    r.opened = opened;
    if (opened === 'open') {
      r.openReadyState = s(() => ms.readyState);
      r.openDuration = s(() => String(ms.duration));
      const sb = s(() => { const b = ms.addSourceBuffer('video/mp4; codecs="avc1.42E01E"'); return Object.prototype.toString.call(b); });
      r.addedSourceBuffer = sb;
      const buf = ms.sourceBuffers[0];
      if (buf) {
        r.sbFields = s(() => Object.getOwnPropertyNames(Object.getPrototypeOf(buf)).map((k) => { try { return `${k}=${String(buf[k])}`; } catch (e) { return `${k}=<${e.name}>`; } }).join(' '));
        r.sbListAfter = s(() => `${ms.sourceBuffers.length}|${String(ms.sourceBuffers[0] === buf)}`);
        r.activeAfter = s(() => ms.activeSourceBuffers.length);
      }
    }
    return r;
  });

  // EME: does a real key system resolve headless, and what comes back.
  out.eme = await sect(async () => {
    const r = {};
    if (typeof navigator.requestMediaKeySystemAccess !== 'function') return 'ABSENT';
    const cfg = [{ initDataTypes: ['cenc'], videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }];
    r.clearkey = await navigator.requestMediaKeySystemAccess('org.w3.clearkey', cfg).then(
      (a) => `OK ${Object.prototype.toString.call(a)} keySystem=${a.keySystem}`,
      (e) => `${e.name}: ${e.message}`);
    r.widevine = await navigator.requestMediaKeySystemAccess('com.widevine.alpha', cfg).then(
      (a) => `OK keySystem=${a.keySystem}`, (e) => `${e.name}: ${e.message}`);
    r.bogus = await navigator.requestMediaKeySystemAccess('com.example.nope', cfg).then(
      () => 'OK', (e) => `${e.name}: ${e.message}`);
    r.emptyConfig = await navigator.requestMediaKeySystemAccess('org.w3.clearkey', []).then(
      () => 'OK', (e) => `${e.name}: ${e.message}`);
    r.noArgs = s(() => navigator.requestMediaKeySystemAccess());

    try {
      const access = await navigator.requestMediaKeySystemAccess('org.w3.clearkey', cfg);
      r.accessConfig = s(() => JSON.stringify(access.getConfiguration()));
      const keys = await access.createMediaKeys();
      r.keys = Object.prototype.toString.call(keys);
      r.setServerCert = await keys.setServerCertificate(new Uint8Array([1, 2, 3])).then(
        (v) => `OK ${String(v)}`, (e) => `${e.name}: ${e.message}`);
      const sess = keys.createSession();
      r.session = Object.prototype.toString.call(sess);
      r.sessionId = s(() => `"${sess.sessionId}"`);
      r.sessionExpiration = s(() => String(sess.expiration));
      r.sessionKeyStatuses = s(() => Object.prototype.toString.call(sess.keyStatuses));
      r.keyStatusesSize = s(() => sess.keyStatuses.size);
      r.closedType = s(() => Object.prototype.toString.call(sess.closed));
      r.createSessionBad = s(() => keys.createSession('nope'));
      r.generateNoArgs = await sess.generateRequest().then(() => 'OK', (e) => `${e.name}: ${e.message}`);
      r.loadEmpty = await sess.load('').then((v) => `OK ${v}`, (e) => `${e.name}: ${e.message}`);
      r.updateBefore = await sess.update(new Uint8Array([1])).then(() => 'OK', (e) => `${e.name}: ${e.message}`);
      r.removeBefore = await sess.remove().then(() => 'OK', (e) => `${e.name}: ${e.message}`);
      r.videoSetMediaKeysCall = await video.setMediaKeys(keys).then(() => `OK mediaKeys=${String(video.mediaKeys === keys)}`, (e) => `${e.name}: ${e.message}`);
    } catch (e) { r.chainThrew = `${e.name}: ${e.message}`; }
    return r;
  });

  // Constructors that a page can call directly.
  out.ctors = {
    MediaMetadata: s(() => { const m = new MediaMetadata({ title: 't', artist: 'a', album: 'b', artwork: [{ src: 'http://x/y.png', sizes: '96x96', type: 'image/png' }] }); return `${m.title}|${m.artist}|${m.album}|${JSON.stringify(m.artwork)}`; }),
    MediaMetadataEmpty: s(() => { const m = new MediaMetadata(); return `"${m.title}"|"${m.artist}"|"${m.album}"|${JSON.stringify(m.artwork)}`; }),
    MediaMetadataArtworkFrozen: s(() => { const m = new MediaMetadata({ artwork: [{ src: 'http://x/y.png' }] }); return `${Object.isFrozen(m.artwork)}|${JSON.stringify(m.artwork[0])}`; }),
    MediaMetadataBadArtwork: s(() => new MediaMetadata({ artwork: [{}] })),
    MediaKeyMessageEvent: s(() => { const e = new MediaKeyMessageEvent('message', { messageType: 'license-request', message: new Uint8Array([1, 2]).buffer }); return `${e.type}|${e.messageType}|${e.message.byteLength}|${e.bubbles}|${e.cancelable}`; }),
    MediaKeyMessageEventNoInit: s(() => new MediaKeyMessageEvent('message')),
    MediaEncryptedEvent: s(() => { const e = new MediaEncryptedEvent('encrypted', { initDataType: 'cenc', initData: new Uint8Array([1]).buffer }); return `${e.type}|${e.initDataType}|${e.initData.byteLength}`; }),
    MediaEncryptedEventNoInit: s(() => { const e = new MediaEncryptedEvent('encrypted'); return `"${e.initDataType}"|${String(e.initData)}`; }),
    ImageCaptureNoArgs: s(() => new ImageCapture()),
    ImageCaptureBadArg: s(() => new ImageCapture({})),
    MediaStreamTrackGeneratorNoArgs: s(() => new MediaStreamTrackGenerator()),
    MediaStreamTrackGeneratorVideo: s(() => { const g = new MediaStreamTrackGenerator({ kind: 'video' }); return `${Object.prototype.toString.call(g)}|kind=${g.kind}|writable=${Object.prototype.toString.call(g.writable)}`; }),
    MediaStreamTrackGeneratorBadKind: s(() => new MediaStreamTrackGenerator({ kind: 'nope' })),
    MediaStreamTrackProcessorNoArgs: s(() => new MediaStreamTrackProcessor()),
    VideoPlaybackQualityNew: s(() => new VideoPlaybackQuality()),
    RemotePlaybackNew: s(() => new RemotePlayback()),
    SourceBufferNew: s(() => new SourceBuffer()),
    MediaKeysNew: s(() => new MediaKeys()),
  };

  // RemotePlayback behaviour off the video element.
  out.remote = await sect(async () => {
    const r = {};
    const rp = video.remote;
    if (!rp) return 'ABSENT';
    r.state = s(() => rp.state);
    r.onconnect = s(() => String(rp.onconnect));
    r.watchNoArgs = await Promise.resolve().then(() => rp.watchAvailability()).then((v) => `OK ${v}`, (e) => `${e.name}: ${e.message}`);
    r.watchCb = await Promise.resolve().then(() => rp.watchAvailability(() => {})).then((v) => `OK id=${typeof v}`, (e) => `${e.name}: ${e.message}`);
    r.cancel = await Promise.resolve().then(() => rp.cancelWatchAvailability()).then(() => 'OK', (e) => `${e.name}: ${e.message}`);
    r.prompt = await Promise.resolve().then(() => rp.prompt()).then(() => 'OK', (e) => `${e.name}: ${e.message}`);
    r.disabled = s(() => String(video.disableRemotePlayback));
    return r;
  });

  // ImageCapture off a real canvas capture track.
  out.imageCapture = await sect(async () => {
    const r = {};
    if (typeof canvas.captureStream !== 'function') return 'no captureStream';
    const track = canvas.captureStream().getVideoTracks()[0];
    if (!track) return 'no track';
    r.trackBrand = Object.prototype.toString.call(track);
    r.trackKind = s(() => track.kind);
    r.trackCanvas = s(() => Object.prototype.toString.call(track.canvas));
    r.trackRequestFrame = s(() => typeof track.requestFrame);
    if (typeof ImageCapture === 'undefined') return r;
    const ic = s(() => { const c = new ImageCapture(track); return Object.prototype.toString.call(c); });
    r.ctor = ic;
    try {
      const c = new ImageCapture(track);
      r.icTrack = s(() => String(c.track === track));
      r.grabFrame = await c.grabFrame().then((b) => `OK ${Object.prototype.toString.call(b)} ${b.width}x${b.height}`, (e) => `${e.name}: ${e.message}`);
      r.takePhoto = await c.takePhoto().then((b) => `OK ${b.type} ${b.size}`, (e) => `${e.name}: ${e.message}`);
      r.getPhotoCapabilities = await c.getPhotoCapabilities().then((p) => `OK ${JSON.stringify(Object.getOwnPropertyNames(Object.getPrototypeOf(p)))}`, (e) => `${e.name}: ${e.message}`);
      r.getPhotoSettings = await c.getPhotoSettings().then((p) => `OK ${JSON.stringify(p)}`, (e) => `${e.name}: ${e.message}`);
    } catch (e) { r.threw = `${e.name}: ${e.message}`; }
    return r;
  });

  out.secureContext = String(window.isSecureContext);
  out.origin = String(location.origin);
  return out;
})()
